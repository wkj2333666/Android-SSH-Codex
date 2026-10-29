import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'connection_keep_alive.dart';
import 'connection_network.dart';
import 'attachments.dart';
import 'diagnostics.dart';
import 'profiles/host_profile.dart';
import 'profiles/profile_store.dart';
import 'projects/remote_project.dart';
import 'projects/shared_project_sync.dart';
import 'protocol/codex_remote_api.dart';
import 'account_usage.dart';
import 'protocol/user_input_request.dart';
import 'protocol/foreground_probe.dart';
import 'protocol/json_rpc_client.dart';
import 'protocol/websocket_rpc_transport.dart';
import 'tasks/task_catalog.dart';
import 'tasks/task_draft.dart';
import 'tasks/turn_settings.dart';
import 'tasks/task_event_batcher.dart';
import 'tasks/task_message_queue.dart';
import 'tasks/task_operation_lock.dart';
import 'tasks/task_reducer.dart';
import 'tasks/task_refresh_lock.dart';
import 'transport/codex_daemon.dart';
import 'transport/connection_setup.dart';
import 'transport/attachment_upload.dart';
import 'transport/file_download.dart' as downloads;
import 'transport/resumable_download.dart';
import 'transport/ssh_connector.dart';
import 'transport/ssh_unix_tunnel.dart';

enum AppSection { hosts, tasks }

enum RemoteConnectionPhase { disconnected, connecting, connected, reconnecting }

enum ConnectionStage {
  profile,
  ssh,
  remoteAppServer,
  unixTunnel,
  rpcTunnel,
  initialize,
  refresh,
}

final class QueuedTaskMessage {
  const QueuedTaskMessage({
    required this.id,
    required this.text,
    this.skill,
    this.model,
    this.effort,
    this.serviceTier,
    this.imagePaths = const [],
  });

  final String id;
  final String text;
  final RemoteSkill? skill;
  final String? model;
  final String? effort;
  final String? serviceTier;
  final List<String> imagePaths;

  String get timelineItemId => 'local-user:$id';

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'model': model,
        'effort': effort,
        'serviceTier': serviceTier,
        'imagePaths': imagePaths,
        if (skill case final s?)
          'skill': {
            'name': s.name,
            'description': s.description,
            'path': s.path,
          },
      };

  factory QueuedTaskMessage.fromJson(Map value) {
    final s = value['skill'] as Map?;
    return QueuedTaskMessage(
        id: value['id'] as String,
        text: value['text'] as String,
        model: value['model'] as String?,
        effort: value['effort'] as String?,
        serviceTier: value['serviceTier'] as String?,
        imagePaths: (value['imagePaths'] as List? ?? const []).cast<String>(),
        skill: s == null
            ? null
            : RemoteSkill(
                name: s['name'] as String,
                description: s['description'] as String,
                path: s['path'] as String));
  }
}

HostProfile? resolveAutoConnectProfile(
  List<HostProfile> profiles,
  String? profileId,
) {
  if (profileId == null) return null;
  return profiles.where((profile) => profile.id == profileId).firstOrNull;
}

Future<String> resolveCodexSocketForProfile(
  SshCommandRunner run,
  HostProfile profile,
) async {
  switch (profile.appServerMode) {
    case AppServerMode.shared:
      return CodexDaemon.startShared(
        run,
        environment: profile.environment,
      );
    case AppServerMode.custom:
      final configuredSocketPath = profile.customAppServerSocket;
      if (configuredSocketPath == null ||
          RegExp(r'[\x00-\x1F\x7F]').hasMatch(configuredSocketPath)) {
        throw const CodexBootstrapException(
          'Custom app-server socket must be an absolute Unix socket path.',
        );
      }
      final socketPath = configuredSocketPath.trim();
      if (socketPath.isEmpty || !socketPath.startsWith('/')) {
        throw const CodexBootstrapException(
          'Custom app-server socket must be an absolute Unix socket path.',
        );
      }
      return socketPath;
    case AppServerMode.isolated:
      return CodexDaemon.bootstrap(
        run,
        environment: profile.environment,
      );
  }
}

bool hasRemoteNotificationVisibleChange({
  required TaskEvent? event,
  required bool activeTurnChanged,
}) =>
    event != null || activeTurnChanged;

bool requiresThreadResumeForSend({required bool subscribed}) => !subscribed;

bool requiresThreadResumeForSteer({required bool subscribed}) => !subscribed;

final class AppController extends ChangeNotifier {
  AppController({required ProfileStore store})
      : _store = store,
        _connector = SshConnector(store);

  factory AppController.memory({
    List<TaskSnapshot> cachedTasks = const [],
    List<RemoteModel> cachedModels = const [],
    ProfileStore? store,
  }) {
    final controller = AppController(store: store ?? MemoryProfileStore());
    controller._workspaceLoaded = true;
    controller._models = cachedModels;
    controller._taskReducer.applyRefresh(
        controller._taskReducer.beginRefresh(controller._epoch),
        cachedTasks, {});
    controller._taskCatalog.replaceRecentPage(cachedTasks, nextCursor: null);
    return controller;
  }

  final ProfileStore _store;

  @visibleForTesting
  factory AppController.connectedForTesting({
    required JsonRpcClient rpc,
    List<TaskSnapshot> cachedTasks = const [],
    ProfileStore? store,
    String hostId = 'test',
  }) {
    final controller =
        AppController.memory(cachedTasks: cachedTasks, store: store);
    controller._rpc = rpc;
    controller._api = CodexRemoteApi(rpc);
    controller.accountUsage.bind(controller._api);
    controller._selectedHostId = hostId;
    controller._workspaceHostId = hostId;
    controller._connectionPhase = RemoteConnectionPhase.connected;
    controller._notificationSubscription = rpc.notifications.listen(
      (event) =>
          controller._handleNotification(controller._connectionAttempt, event),
    );
    return controller;
  }
  final SshConnector _connector;
  final ConnectionKeepAlive _keepAlive = ConnectionKeepAlive();
  late final ConnectionNetwork _network = ConnectionNetwork(_networkChanged);
  bool _networkAvailable = true;
  String? _keepAliveWarning;
  final TaskReducer _taskReducer = TaskReducer();
  late final TaskEventBatcher _agentDeltaBatcher = TaskEventBatcher(
    onFlush: _applyAgentDeltaBatch,
  );
  final TaskCatalog _taskCatalog = TaskCatalog();
  final TaskHistoryLoadState _historyLoadState = TaskHistoryLoadState();
  final Map<String, TaskMessageQueue<QueuedTaskMessage>> _outboxes = {};
  TaskMessageQueue<QueuedTaskMessage> get _messageQueue =>
      _outboxes.putIfAbsent(
          _workspaceHostId ?? _selectedHostId ?? '', TaskMessageQueue.new);
  final Map<String, String> _deliveryStates = {};
  final Map<(String, String), Map<String, dynamic>> _savedDrafts = {};
  Timer? _draftSaveTimer;
  Future<void> _workspaceWrite = Future.value();
  bool _disposed = false;
  bool _workspaceLoaded = false;
  final Map<String, RemoteThreadGoal?> _goals = {};
  final Map<String, int> _goalRevisions = {};
  Timer? _projectSyncTimer;
  final TaskOperationLock _messageOperations = TaskOperationLock();
  final Map<String, Set<String>> _inFlightQueuedMessageIds = {};
  final TaskRefreshLock<CodexRemoteApi> _refreshOperations = TaskRefreshLock();

  List<HostProfile> _profiles = const [];
  List<RemoteProject> _projects = const [];
  List<RemoteModel> _models = const [];
  final AccountUsageController accountUsage = AccountUsageController();
  AppSection _section = AppSection.hosts;
  RemoteConnectionPhase _connectionPhase = RemoteConnectionPhase.disconnected;
  String? _selectedHostId;
  String? _workspaceHostId;
  final Map<String, List<String>> _cachedProjectTaskIds = {};
  String? _selectedProjectId;
  String? _selectedTaskId;
  final Map<String, String> _activeTurnIds = {};
  final Map<String, DateTime> _projectActivityByCwd = {};
  String? _error;
  HostKeyChallenge? _hostKeyChallenge;
  Completer<bool>? _hostKeyCompleter;
  List<PendingApproval> _approvals = const [];
  List<UserInputRequest> _userInputRequests = const [];
  List<UserInputRequest> get userInputRequests => _userInputRequests;
  final Set<String> _interactiveThreadIds = {};
  Set<String> _subscribedThreadIds = {};
  final Map<String, Future<void>> _pendingThreadSubscriptions = {};
  SshConnection? _ssh;
  SshUnixTunnel? _tunnel;
  JsonRpcClient? _rpc;
  CodexRemoteApi? _api;
  CodexRemoteApi? _projectDiscoveryApi;
  CodexRemoteApi? _sharedProjectsApi;
  CodexRemoteApi? _unsupportedProjectsApi;
  CodexRemoteApi? _projectOperationApi;
  Future<void> _projectOperation = Future.value();
  StreamSubscription<RpcNotification>? _notificationSubscription;
  StreamSubscription<RpcServerRequest>? _requestSubscription;
  Timer? _refreshTimer;
  Timer? _reconnectTimer;
  bool _inBackground = false;
  bool _expediteReconnect = false;
  ConnectionSetup? _openingAttempt;
  CodexRemoteApi? _foregroundProbeApi;
  var _epoch = 0;
  var _connectionAttempt = 0;
  var _reconnectAttempt = 0;
  var _loadingProjectPage = false;
  var _loadingRecentPage = false;
  var _loadingUnassignedPage = false;
  var _projectPageGeneration = 0;
  var _nextQueuedMessageId = 0;
  Future<void> _autoConnectIntentWrite = Future.value();

  List<HostProfile> get profiles => _profiles;
  List<RemoteProject> get projects => _projects;
  List<RemoteModel> get models => _models;
  AppSection get section => _section;
  RemoteConnectionPhase get connectionPhase => _connectionPhase;
  final Map<(String, String), TaskDraft> _drafts = {};

  TaskDraft draftForTask(String taskId) {
    final hostId = _selectedHostId ?? '';
    return _drafts.putIfAbsent((hostId, taskId), () {
      final draft = TaskDraft(
        retainFilesOnDispose: _store is WorkspaceStore,
        canUpload: () =>
            isConnected &&
            _selectedHostId == hostId &&
            _workspaceHostId == hostId,
        upload: (attachment, target, cancellation, {onProgress}) {
          if (_selectedHostId != hostId) {
            throw StateError(
                'Reconnect to the original host to resume upload.');
          }
          return uploadAttachmentNow(attachment, target, cancellation,
              onProgress: onProgress);
        },
      );
      final saved = _savedDrafts[(hostId, taskId)];
      if (saved != null) draft.restore(saved);
      void save() {
        if (_disposed || draft.sending) return;
        _savedDrafts[(hostId, taskId)] = draft.toJson();
        _draftSaveTimer?.cancel();
        _draftSaveTimer = Timer(const Duration(milliseconds: 200), () {
          unawaited(_saveWorkspace().catchError((Object error) {
            _error = 'Could not save draft: $error';
            if (!_disposed) notifyListeners();
          }));
        });
      }

      draft.composer.addListener(save);
      draft.addListener(save);
      return draft;
    });
  }

  String? deliveryState(String id) => _deliveryStates[id];
  RemoteThreadGoal? get selectedGoal => _goals[_selectedTaskId];

  Future<void> _restoreWorkspace() async {
    final store = _store;
    if (store is! WorkspaceStore) return;
    final saved = await (store as WorkspaceStore).readWorkspace();
    for (final raw in saved['drafts'] as List? ?? const []) {
      final entry = raw as Map;
      _savedDrafts[(entry['host'] as String, entry['task'] as String)] =
          (entry['draft'] as Map).cast<String, dynamic>();
    }
    for (final raw in saved['outbox'] as List? ?? const []) {
      final entry = raw as Map;
      final message = QueuedTaskMessage.fromJson(entry['message'] as Map);
      final host = entry['host'] as String;
      _outboxes
          .putIfAbsent(host, TaskMessageQueue.new)
          .enqueue(entry['task'] as String, message);
      _deliveryStates[message.id] = entry['state'] == 'sending'
          ? 'uncertain'
          : entry['state'] as String? ?? 'queued';
    }
    _workspaceLoaded = true;
  }

  Future<void> _saveWorkspace() {
    final store = _store;
    if (store is! WorkspaceStore) return Future.value();
    if (!_workspaceLoaded) {
      return Future.error(StateError('Draft storage has not been restored.'));
    }
    final snapshot = <String, dynamic>{
      'drafts': [
        for (final entry in _savedDrafts.entries)
          {'host': entry.key.$1, 'task': entry.key.$2, 'draft': entry.value}
      ],
      'outbox': [
        for (final host in _outboxes.entries)
          for (final task in host.value.threadIds)
            for (final message in host.value.values(task))
              {
                'host': host.key,
                'task': task,
                'message': message.toJson(),
                'state': _deliveryStates[message.id] ?? 'queued',
              }
      ],
    };
    final result = _workspaceWrite
        .then((_) => (store as WorkspaceStore).writeWorkspace(snapshot));
    _workspaceWrite = result.catchError((Object _) {});
    return result;
  }

  Future<void> flushWorkspace() async {
    _draftSaveTimer?.cancel();
    if (!_workspaceLoaded) return;
    await _saveWorkspace();
  }

  String? get selectedHostId => _selectedHostId;
  String? get selectedProjectId => _selectedProjectId;
  String? get selectedTaskId => _selectedTaskId;
  String? get error => _error ?? _keepAliveWarning;
  HostKeyChallenge? get hostKeyChallenge => _hostKeyChallenge;
  List<PendingApproval> get approvals => _approvals;
  TaskState get taskState => _taskReducer.state;
  bool get unassignedExpanded => _taskCatalog.unassignedExpanded;
  bool get hasMoreProjectTasks => _taskCatalog.projectNextCursor != null;
  bool get hasMoreRecentTasks => _taskCatalog.recentNextCursor != null;
  bool get hasMoreUnassignedTasks => _taskCatalog.unassignedNextCursor != null;
  bool get isLoadingProjectPage => _loadingProjectPage;
  bool get isLoadingRecentTasks => _loadingRecentPage;
  bool get isLoadingUnassignedPage => _loadingUnassignedPage;
  bool get hasOlderTaskContext =>
      _historyLoadState.taskId == _selectedTaskId && _historyLoadState.hasOlder;
  bool get isLoadingOlderTaskContext =>
      _historyLoadState.taskId == _selectedTaskId &&
      _historyLoadState.isLoadingOlder;
  String? get olderTaskContextError =>
      _historyLoadState.taskId == _selectedTaskId
          ? _historyLoadState.olderError
          : null;

  HostProfile? get selectedHost =>
      _profiles.where((profile) => profile.id == _selectedHostId).firstOrNull;

  RemoteProject? get selectedProject => _selectedProjectId == null
      ? null
      : _projects
          .where((project) => project.id == _selectedProjectId)
          .firstOrNull;

  List<TaskRecord> get projectTasks =>
      _tasksForIds(_taskCatalog.projectTaskIds);

  List<TaskRecord> get recentTasks => _tasksForIds(_taskCatalog.recentTaskIds);

  List<TaskRecord> get unassignedTasks =>
      _tasksForIds(_taskCatalog.unassignedTaskIds);

  TaskRecord? get selectedTask => _selectedTaskId == null
      ? null
      : _taskReducer.state.tasks[_selectedTaskId];

  bool get isConnected => _connectionPhase == RemoteConnectionPhase.connected;

  bool isTaskDetailLoading(String taskId) =>
      _historyLoadState.taskId == taskId && _historyLoadState.isInitialLoading;

  String? taskDetailError(String taskId) => _historyLoadState.taskId == taskId
      ? _historyLoadState.initialError
      : null;

  List<QueuedTaskMessage> queuedMessagesForTask(String taskId) =>
      _messageQueue.values(taskId);

  Set<String> inFlightQueuedMessageIdsForTask(String taskId) =>
      Set.unmodifiable(_inFlightQueuedMessageIds[taskId] ?? const <String>{});

  Future<void> initialize() async {
    HostProfile? autoConnectProfile;
    try {
      _profiles = await _store.readProfiles();
      autoConnectProfile = resolveAutoConnectProfile(
        _profiles,
        await _store.readAutoConnectHostId(),
      );
    } catch (exception) {
      _profiles = const [];
      _error = 'Could not read secure storage: $exception';
    }
    try {
      await _restoreWorkspace();
    } catch (exception) {
      _workspaceLoaded = false;
      _error = 'Could not restore drafts and queued messages: $exception';
    }
    notifyListeners();
    if (autoConnectProfile != null) {
      unawaited(connectHost(autoConnectProfile));
    }
  }

  void observeNetwork() => unawaited(_network.start());

  void selectSection(AppSection section) {
    if (_section == section) return;
    _section = section;
    notifyListeners();
  }

  Future<void> saveProfile(HostProfile profile, HostSecret secret) async {
    await _store.writeProfile(profile, secret);
    _profiles = await _store.readProfiles();
    _selectedHostId = profile.id;
    notifyListeners();
  }

  Future<void> deleteProfile(String id) async {
    if (_selectedHostId == id) await disconnect();
    if (_workspaceHostId == id) {
      _workspaceHostId = null;
      _models = const [];
      _projects = const [];
      _selectedTaskId = null;
      _selectedProjectId = null;
      _taskCatalog.clear();
      _cachedProjectTaskIds.clear();
      _epoch = _taskReducer.beginConnection();
    }
    for (final key in _drafts.keys.where((key) => key.$1 == id).toList()) {
      final draft = _drafts.remove(key);
      if (draft != null) {
        for (final file in draft.attachments.toList()) {
          draft.removeAttachment(file);
        }
        draft.dispose();
      }
    }
    _savedDrafts.removeWhere((key, _) => key.$1 == id);
    _outboxes.remove(id);
    await _saveWorkspace();
    await _store.deleteProfile(id);
    _profiles = await _store.readProfiles();
    notifyListeners();
  }

  Future<HostSecret> readSecret(String id) => _store.readSecret(id);

  Future<void> connectHost(HostProfile profile) async {
    cancelDownload();
    final preserveWorkspace = _workspaceHostId == profile.id;
    final attempt = ++_connectionAttempt;
    _openingAttempt?.cancel(StateError('Connection replaced'));
    _cancelHostKeyPrompt();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    _messageOperations.clear();
    _inFlightQueuedMessageIds.clear();
    await _closeTransport();
    if (attempt != _connectionAttempt) return;
    _agentDeltaBatcher.clear();
    _epoch = _taskReducer.beginConnection(clearTasks: !preserveWorkspace);
    if (!preserveWorkspace) {
      _models = const [];
      _projects = const [];
      _selectedProjectId = null;
      _selectedTaskId = null;
      _taskCatalog.clear();
      _cachedProjectTaskIds.clear();
    }
    _workspaceHostId = profile.id;
    _goals.clear();
    _goalRevisions.clear();
    await _openConnection(profile,
        attempt: attempt,
        reconnecting: false,
        preserveWorkspace: preserveWorkspace);
  }

  Future<void> _openConnection(
    HostProfile profile, {
    required int attempt,
    required bool reconnecting,
    bool preserveWorkspace = false,
  }) async {
    final setup = ConnectionSetup(attempt);
    _openingAttempt = setup;
    Diagnostics.record('connection.open', {
      'attempt': attempt,
      'reconnecting': reconnecting,
      'background': _inBackground,
    });
    _selectedHostId = profile.id;
    if (!reconnecting && !preserveWorkspace) _selectedTaskId = null;
    _connectionPhase = reconnecting
        ? RemoteConnectionPhase.reconnecting
        : RemoteConnectionPhase.connecting;
    _error = null;
    _section = AppSection.tasks;
    notifyListeners();

    SshConnection? ssh;
    SshUnixTunnel? tunnel;
    JsonRpcClient? rpc;
    StreamSubscription<RpcNotification>? notifications;
    StreamSubscription<RpcServerRequest>? requests;
    var published = false;
    var stage = ConnectionStage.profile;
    try {
      if (!_inBackground) {
        await setup.run('keepAlive', () => _setKeepAlive(true));
      }
      if (attempt != _connectionAttempt) return;
      final secret =
          await setup.run('profileSecret', () => _store.readSecret(profile.id));
      final projects = reconnecting || preserveWorkspace
          ? _projects
          : await setup.run(
              'profileProjects', () => _store.readProjects(profile.id));
      if (attempt != _connectionAttempt) return;
      if (!reconnecting && !preserveWorkspace) {
        _projectActivityByCwd.clear();
        _projects = projects;
        _selectedProjectId = projects.firstOrNull?.id;
        _taskCatalog.clear();
        _historyLoadState.clear();
      }
      stage = ConnectionStage.ssh;
      ssh = await setup.run<SshConnection>(
        stage.name,
        () => _connector.connect(
          profile,
          secret,
          prompt: (challenge) {
            if (attempt != _connectionAttempt) return Future.value(false);
            return _promptForHostKey(challenge);
          },
          diagnosticAttempt: attempt,
          setup: setup,
        ),
        timeout: profile.sshOptions
            .setupTimeout(hasJumpHost: profile.proxyJump != null),
        closeLateResult: (connection) =>
            connection.close(reason: 'late_connection_setup_result'),
      );
      if (attempt != _connectionAttempt) return;
      stage = ConnectionStage.remoteAppServer;
      final client = ssh.client;
      final socketPath = await setup.run(
          stage.name,
          () => resolveCodexSocketForProfile(
                (command, {environment}) async {
                  final commandWatch = Stopwatch()..start();
                  final result = await client.runWithResult(
                    command,
                    environment: environment,
                  );
                  Diagnostics.record('bootstrap.commandResult', {
                    'attempt': attempt,
                    'mode': profile.appServerMode.name,
                    'durationMs': commandWatch.elapsedMilliseconds,
                    'exitCode': result.exitCode,
                    'exitSignal': result.exitSignal?.signalName,
                    'stdoutBytes': result.stdout.length,
                    'stderrBytes': result.stderr.length,
                  });
                  return SshCommandResult(
                    stdout: result.stdout,
                    stderr: result.stderr,
                    exitCode: result.exitCode,
                    exitSignal: result.exitSignal?.signalName,
                  );
                },
                profile,
              ));
      if (attempt != _connectionAttempt) return;
      stage = ConnectionStage.unixTunnel;
      tunnel = await setup.run<SshUnixTunnel>(
          stage.name,
          () => SshUnixTunnel.start(
                client,
                socketPath,
                environment: profile.environment,
              ),
          closeLateResult: (value) => value.close());
      if (attempt != _connectionAttempt) return;
      stage = ConnectionStage.rpcTunnel;
      final activeTunnel = tunnel;
      setup.watchClosed(activeTunnel.firstFailure, () {});
      final transport = await setup.run(
          stage.name,
          () => WebSocketRpcTransport.connect(
                Uri.parse('ws://127.0.0.1:${activeTunnel.localPort}/'),
              ),
          closeLateResult: (value) =>
              boundedConnectionCleanup('lateWebSocket', value.close));
      rpc = JsonRpcClient(transport)..start();
      setup.watchClosed(rpc.done, () {});
      final api = CodexRemoteApi(rpc);
      notifications = api.notifications.listen(
        (notification) => _handleNotification(attempt, notification),
      );
      requests = api.serverRequests.listen(
        (request) => _handleServerRequest(attempt, request),
      );
      stage = ConnectionStage.initialize;
      await setup.run(stage.name, api.initialize);
      if (attempt != _connectionAttempt) return;
      final catalog = await setup.run('modelCatalog', () async {
        try {
          return await api.readModelCatalog();
        } catch (exception) {
          debugPrint('Could not read remote model catalog: $exception');
          return _models;
        }
      });
      if (attempt != _connectionAttempt) return;
      _models = catalog;
      if (attempt != _connectionAttempt) return;

      _ssh = ssh;
      _tunnel = tunnel;
      _rpc = rpc;
      _api = api;
      _notificationSubscription = notifications;
      _requestSubscription = requests;
      _subscribedThreadIds = {};
      published = true;
      unawaited(rpc.done.then((_) => _handleTransportLoss(attempt, profile)));
      stage = ConnectionStage.refresh;
      await setup.run(
          stage.name, () => refreshTasks(throwOnError: true, resetPages: true));
      if (attempt != _connectionAttempt) return;
      _connectionPhase = RemoteConnectionPhase.connected;
      setup.dispose();
      if (identical(_openingAttempt, setup)) _openingAttempt = null;
      accountUsage.bind(api);
      unawaited(accountUsage.refresh());
      Diagnostics.record('connection.ready', {'attempt': attempt});
      _reconnectAttempt = 0;
      _expediteReconnect = false;
      if (reconnecting || preserveWorkspace) {
        await _recoverSelectedTaskAfterReconnect(
          api,
          attempt: attempt,
          epoch: _epoch,
          profileId: profile.id,
        );
      }
      if (attempt != _connectionAttempt) return;
      notifyListeners();
      _startProjectDiscovery(
        api,
        attempt: attempt,
        epoch: _epoch,
        profileId: profile.id,
      );
      await _rememberAutoConnectHost(profile.id);
      if (attempt != _connectionAttempt) return;
      _startRefreshTimer();
      _flushReadyQueuedPrompts();
      for (final key in _savedDrafts.keys.toList()) {
        if (key.$1 == profile.id) draftForTask(key.$2);
      }
      for (final entry in _drafts.entries) {
        if (entry.key.$1 == profile.id) entry.value.resumeWaitingUploads();
      }
    } catch (exception, stackTrace) {
      if (attempt != _connectionAttempt) return;
      _cancelHostKeyPrompt();
      Diagnostics.record('connection.failed', {
        'attempt': attempt,
        'stage': stage.name,
        'appServerMode': profile.appServerMode.name,
        ...Diagnostics.errorFields(exception,
            sensitiveValues: profile.environment.values),
      });
      debugPrint(
        'Connection failed during ${stage.name} for '
        '${profile.hostName}:${profile.port}: $exception',
      );
      debugPrintStack(stackTrace: stackTrace);
      _error = describeConnectionFailure(stage, exception, profile);
      if (published) await _closeTransport(reason: 'connection_setup_failed');
      if (attempt != _connectionAttempt) return;
      if (reconnecting) {
        _connectionPhase = RemoteConnectionPhase.reconnecting;
        _scheduleReconnect(profile, attempt);
      } else {
        _connectionPhase = RemoteConnectionPhase.disconnected;
        await _setKeepAlive(false);
      }
    } finally {
      setup.dispose();
      if (identical(_openingAttempt, setup)) _openingAttempt = null;
      if (!published) {
        await Future.wait([
          if (notifications != null)
            boundedConnectionCleanup('notifications', notifications.cancel),
          if (requests != null)
            boundedConnectionCleanup('requests', requests.cancel),
          if (rpc != null) boundedConnectionCleanup('rpc', rpc.close),
          if (tunnel != null) boundedConnectionCleanup('tunnel', tunnel.close),
          if (ssh != null)
            boundedConnectionCleanup('ssh',
                () => ssh!.close(reason: 'unpublished_connection_cleanup')),
        ]);
      }
    }
    notifyListeners();
  }

  Future<void> _handleTransportLoss(int attempt, HostProfile profile) async {
    Diagnostics.record('connection.transportLoss', {
      'attempt': attempt,
      'currentAttempt': _connectionAttempt,
      'phase': _connectionPhase.name,
      'background': _inBackground,
    });
    if (attempt != _connectionAttempt ||
        _connectionPhase != RemoteConnectionPhase.connected) {
      return;
    }
    _connectionPhase = RemoteConnectionPhase.reconnecting;
    _error = 'Remote connection lost. Reconnecting...';
    notifyListeners();
    await _closeTransport(reason: 'transport_loss_cleanup');
    if (attempt == _connectionAttempt) {
      notifyListeners();
      _scheduleReconnect(profile, attempt);
    }
  }

  void _scheduleReconnect(HostProfile profile, int attempt,
      {bool immediate = false}) {
    if (!_networkAvailable ||
        (_inBackground && !_keepAlive.isEnabled) ||
        attempt != _connectionAttempt ||
        _reconnectTimer != null) {
      return;
    }
    const delays = [1, 2, 4, 8, 15];
    final delayIndex = _reconnectAttempt < delays.length
        ? _reconnectAttempt
        : delays.length - 1;
    final seconds = immediate || _expediteReconnect ? 0 : delays[delayIndex];
    Diagnostics.record('connection.retryScheduled', {
      'attempt': attempt,
      'delaySeconds': seconds,
      'background': _inBackground,
      'keepAliveCached': _keepAlive.isEnabled,
    });
    _expediteReconnect = false;
    _reconnectAttempt++;
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      _reconnectTimer = null;
      if (attempt != _connectionAttempt) return;
      final nextAttempt = ++_connectionAttempt;
      _agentDeltaBatcher.clear();
      _epoch = _taskReducer.beginConnection(clearTasks: false);
      unawaited(_openConnection(
        profile,
        attempt: nextAttempt,
        reconnecting: true,
      ));
    });
  }

  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (_inBackground || !isConnected) return;
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(refreshTasks()),
    );
  }

  Future<void> _networkChanged(bool available) async {
    _networkAvailable = available;
    Diagnostics.record('connection.networkChanged', {'available': available});
    if (!available) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      return;
    }
    final profile = _profiles.where((p) => p.id == _selectedHostId).firstOrNull;
    if (profile == null) return;
    if (_openingAttempt case final setup?) {
      setup.checkDeadline();
      return;
    }
    if (_connectionPhase == RemoteConnectionPhase.reconnecting) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _scheduleReconnect(profile, _connectionAttempt, immediate: true);
      return;
    }
    final api = _api;
    final rpc = _rpc;
    if (!isConnected ||
        api == null ||
        rpc == null ||
        _foregroundProbeApi == api) {
      return;
    }
    _foregroundProbeApi = api;
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    try {
      final sshHealthy = await _ssh?.checkHealth() ?? false;
      final disconnected =
          !sshHealthy || await foregroundTransportDisconnected(rpc);
      if (!_isCurrentSession(api, attempt, epoch, profile.id)) return;
      if (disconnected) {
        _expediteReconnect = true;
        await _handleTransportLoss(attempt, profile);
      } else if (available) {
        await _recoverSelectedTaskAfterReconnect(api,
            attempt: attempt, epoch: epoch, profileId: profile.id);
      }
    } catch (error) {
      Diagnostics.record(
          'connection.networkRecovery.error', Diagnostics.errorFields(error));
    } finally {
      if (_foregroundProbeApi == api) _foregroundProbeApi = null;
    }
  }

  void enterBackground() {
    unawaited(flushWorkspace().catchError((Object error) {
      _error = 'Could not save draft: $error';
    }));
    Diagnostics.record('connection.background', {
      'phase': _connectionPhase.name,
      'attempt': _connectionAttempt,
      'keepAliveCached': _keepAlive.isEnabled,
    });
    _inBackground = true;
    _expediteReconnect = false;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (!_keepAlive.isEnabled) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    }
    // Keep the transport; backgrounding is not an explicit disconnect.
  }

  Future<void> _setKeepAlive(bool enabled) async {
    final attempt = _connectionAttempt;
    try {
      await _keepAlive.setEnabled(enabled, verifyNative: enabled);
      if (attempt == _connectionAttempt) _keepAliveWarning = null;
    } catch (exception) {
      if (attempt != _connectionAttempt) return;
      _keepAliveWarning = 'Background connection protection: $exception';
      Diagnostics.record('keepAlive.error', Diagnostics.errorFields(exception));
      debugPrint(_keepAliveWarning);
    }
  }

  Future<void> restoreForegroundConnection() async {
    Diagnostics.record('connection.foreground', {
      'phase': _connectionPhase.name,
      'attempt': _connectionAttempt,
      'keepAliveCached': _keepAlive.isEnabled,
    });
    _inBackground = false;
    _expediteReconnect = true;
    final profile =
        _profiles.where((profile) => profile.id == _selectedHostId).firstOrNull;
    // Respect explicit disconnect, and never overlap an in-flight connection.
    if (profile == null) return;
    if (_openingAttempt case final setup?) {
      setup.checkDeadline();
      return;
    }
    if (_connectionPhase != RemoteConnectionPhase.disconnected) {
      final attempt = _connectionAttempt;
      await _setKeepAlive(true);
      if (attempt != _connectionAttempt ||
          _connectionPhase == RemoteConnectionPhase.disconnected) {
        return;
      }
    }
    if (_connectionPhase == RemoteConnectionPhase.reconnecting) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _scheduleReconnect(profile, _connectionAttempt, immediate: true);
      return;
    }
    final api = _api;
    final rpc = _rpc;
    if (!isConnected ||
        api == null ||
        rpc == null ||
        _foregroundProbeApi == api) {
      return;
    }
    _foregroundProbeApi = api;
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    try {
      final sshHealthy = await _ssh?.checkHealth() ?? false;
      final disconnected =
          !sshHealthy || await foregroundTransportDisconnected(rpc);
      if (!_isCurrentSession(api, attempt, epoch, profile.id) ||
          _inBackground) {
        return;
      }
      if (disconnected) {
        await _handleTransportLoss(attempt, profile);
        return;
      }
      _expediteReconnect = false;
      _startRefreshTimer();
      unawaited(_recoverSelectedTaskAfterReconnect(
        api,
        attempt: attempt,
        epoch: epoch,
        profileId: profile.id,
      ));
      if (_isCurrentSession(api, attempt, epoch, profile.id) &&
          !_inBackground) {
        unawaited(refreshTasks());
      }
    } catch (exception) {
      if (_isCurrentSession(api, attempt, epoch, profile.id)) {
        debugPrint('Foreground connection check failed: $exception');
        // Resume polling even if catch-up preparation failed. Only a confirmed
        // transport disconnect (above or rpc.done) may tear down this session.
        _expediteReconnect = false;
        _startRefreshTimer();
      }
    } finally {
      if (_foregroundProbeApi == api) _foregroundProbeApi = null;
    }
  }

  Future<bool> _promptForHostKey(HostKeyChallenge challenge) async {
    _hostKeyCompleter?.complete(false);
    final completer = Completer<bool>();
    _hostKeyCompleter = completer;
    _hostKeyChallenge = challenge;
    notifyListeners();
    return completer.future;
  }

  void answerHostKey(bool accepted) {
    final completer = _hostKeyCompleter;
    _hostKeyCompleter = null;
    _hostKeyChallenge = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(accepted);
    }
    notifyListeners();
  }

  void _cancelHostKeyPrompt() {
    final completer = _hostKeyCompleter;
    _hostKeyCompleter = null;
    _hostKeyChallenge = null;
    if (completer != null && !completer.isCompleted) completer.complete(false);
  }

  Future<void> refreshTasks({
    bool throwOnError = false,
    bool resetPages = false,
  }) async {
    final api = _api;
    final epoch = _epoch;
    final connecting = _connectionPhase == RemoteConnectionPhase.connecting ||
        _connectionPhase == RemoteConnectionPhase.reconnecting;
    if (api == null || (!isConnected && !connecting)) return;
    final operation = _refreshOperations.tryAcquire(
      api,
      epoch,
      resetPages: resetPages,
    );
    if (operation == null) return;
    var resetNext = resetPages;
    try {
      while (true) {
        final shouldResetPages = resetNext;
        resetNext = false;
        await _syncSharedProjects(api, epoch);
        if (api != _api || epoch != _epoch) return;
        final initialProject = selectedProject;
        final token = _taskReducer.beginRefresh(epoch);
        final unassignedFuture = api.readTaskPage();
        final initialProjectFuture = initialProject == null
            ? Future<RemoteTaskPage?>.value()
            : _readProjectTasks(api, initialProject);
        final unassignedPage = await unassignedFuture;
        if (api != _api || epoch != _epoch) return;
        _discoverProjects(unassignedPage.tasks);
        final project = selectedProject;
        final selectedProjectId = project?.id;
        final projectPage = project == null
            ? null
            : initialProject?.id == project.id
                ? await initialProjectFuture
                : await _readProjectTasks(api, project);
        if (api != _api || epoch != _epoch) return;
        if (selectedProjectId != _selectedProjectId) {
          resetNext = true;
          continue;
        }
        final snapshots = <String, TaskSnapshot>{
          for (final task in unassignedPage.tasks) task.id: task,
          if (projectPage != null)
            for (final task in projectPage.tasks) task.id: task,
        };
        final loadedByUs = _interactiveThreadIds;
        _taskReducer.applyRefresh(
          token,
          snapshots.values.toList(growable: false),
          loadedByUs,
          retainExisting: true,
        );
        if (projectPage == null) {
          _taskCatalog.clearProjectPage();
        } else if (shouldResetPages) {
          _taskCatalog.replaceProjectPage(
            projectPage.tasks,
            nextCursor: projectPage.nextCursor,
          );
        } else {
          _taskCatalog.mergeProjectHead(
            projectPage.tasks,
            nextCursor: projectPage.nextCursor,
          );
        }
        if (shouldResetPages) {
          _taskCatalog.replaceRecentPage(
            unassignedPage.tasks,
            nextCursor: unassignedPage.nextCursor,
          );
        } else {
          _taskCatalog.mergeRecentHead(
            unassignedPage.tasks,
            nextCursor: unassignedPage.nextCursor,
          );
        }
        if (shouldResetPages) {
          _taskCatalog.replaceUnassignedPage(
            unassignedPage.tasks,
            projects: _projects,
            nextCursor: unassignedPage.nextCursor,
          );
        } else {
          _taskCatalog.mergeUnassignedHead(
            unassignedPage.tasks,
            projects: _projects,
            nextCursor: unassignedPage.nextCursor,
          );
        }
        _taskCatalog.reconcileSharedMembership(
          snapshots.values,
          project?.remoteId,
        );
        notifyListeners();
        if (isConnected) _flushReadyQueuedPrompts();
        final queuedResetPages = operation.takeQueuedResetPages();
        if (queuedResetPages == null || !isConnected) break;
        resetNext = queuedResetPages;
      }
    } catch (exception) {
      if (throwOnError) rethrow;
      _error = _friendlyError(exception);
      notifyListeners();
    } finally {
      _refreshOperations.release(operation);
    }
  }

  Future<void> selectTask(String taskId) async {
    _selectedTaskId = taskId;
    _section = AppSection.tasks;
    _historyLoadState.clear();
    notifyListeners();
    await _loadInitialTaskContext(taskId);
  }

  void clearSelectedTask() {
    _selectedTaskId = null;
    _historyLoadState.clear();
    notifyListeners();
  }

  Future<void> retrySelectedTaskDetails() async {
    final taskId = _selectedTaskId;
    if (taskId != null) await _loadInitialTaskContext(taskId);
  }

  Future<void> _loadInitialTaskContext(String taskId) async {
    final api = _api;
    final epoch = _epoch;
    if (api == null || !isConnected) return;
    unawaited(_refreshGoal(taskId));
    final attempt = _connectionAttempt;
    final profileId = _selectedHostId!;
    final token = _historyLoadState.beginInitial(taskId);
    notifyListeners();
    try {
      String? subscriptionError;
      try {
        await _ensureThreadSubscribed(taskId,
            api: api, attempt: attempt, epoch: epoch, profileId: profileId);
      } catch (exception) {
        subscriptionError =
            'Live updates unavailable: ${_friendlyError(exception)}';
      }
      if (!_isCurrentSession(api, attempt, epoch, profileId) ||
          _selectedTaskId != taskId) {
        return;
      }
      _agentDeltaBatcher.flush();
      final readToken = _taskReducer.captureItemsRead(epoch, taskId);
      final page = await api.readThreadTurnsPage(taskId);
      if (api != _api || epoch != _epoch) return;
      if (!_historyLoadState.complete(token, nextCursor: page.nextCursor)) {
        return;
      }
      _agentDeltaBatcher.flush();
      _taskReducer.mergeLatestItems(epoch, taskId, page.items,
          readToken: readToken);
      if (subscriptionError != null) {
        _historyLoadState.fail(token, subscriptionError);
      }
    } catch (exception) {
      if (api != _api || epoch != _epoch) return;
      _historyLoadState.fail(token, _friendlyError(exception));
    }
    notifyListeners();
  }

  Future<void> loadOlderSelectedTaskContext() async {
    final api = _api;
    final epoch = _epoch;
    if (api == null || !isConnected) return;
    final token = _historyLoadState.beginOlder();
    if (token == null) return;
    notifyListeners();
    try {
      final page = await api.readThreadTurnsPage(
        token.taskId,
        cursor: token.cursor,
      );
      if (api != _api || epoch != _epoch || token.taskId != _selectedTaskId) {
        return;
      }
      if (!_historyLoadState.complete(token, nextCursor: page.nextCursor)) {
        return;
      }
      _taskReducer.prependItems(epoch, token.taskId, page.items);
    } catch (exception) {
      if (api != _api || epoch != _epoch) return;
      _historyLoadState.fail(token, _friendlyError(exception));
    }
    notifyListeners();
  }

  Future<void> selectProject(String? projectId) async {
    final project = projectId == null
        ? null
        : _projects.where((project) => project.id == projectId).firstOrNull;
    if (projectId != null && project == null) return;
    if (_selectedProjectId == projectId) return;
    if (_selectedProjectId case final previous?) {
      _cachedProjectTaskIds[previous] = List.of(_taskCatalog.projectTaskIds);
    }
    _selectedProjectId = projectId;
    _selectedTaskId = null;
    _historyLoadState.clear();
    _taskCatalog
        .restoreCachedProjectPage(_cachedProjectTaskIds[projectId] ?? const []);
    final api = _api;
    final epoch = _epoch;
    final pageToken = _taskReducer.capturePageMerge(epoch);
    final catalogGeneration = _taskCatalog.projectGeneration;
    final generation = ++_projectPageGeneration;
    if (project == null || api == null || !isConnected) {
      _loadingProjectPage = false;
      notifyListeners();
      return;
    }
    _loadingProjectPage = true;
    notifyListeners();
    try {
      final page = await _readProjectTasks(api, project);
      if (api != _api ||
          epoch != _epoch ||
          generation != _projectPageGeneration ||
          project.id != _selectedProjectId) {
        return;
      }
      if (!_taskCatalog.isCurrentProjectGeneration(catalogGeneration)) return;
      _discoverProjects(page.tasks);
      final applied = _taskReducer.applyPageMerge(
        pageToken,
        page.tasks,
        _interactiveThreadIds,
      );
      if (!applied) return;
      _taskCatalog.replaceProjectPage(
        page.tasks,
        nextCursor: page.nextCursor,
      );
    } catch (exception) {
      if (api == _api &&
          epoch == _epoch &&
          generation == _projectPageGeneration) {
        _error = _friendlyError(exception);
      }
    } finally {
      if (generation == _projectPageGeneration) {
        _loadingProjectPage = false;
        notifyListeners();
      }
    }
  }

  Future<RemoteTaskPage> _readProjectTasks(
    CodexRemoteApi api,
    RemoteProject project, {
    String? cursor,
  }) =>
      api.readTaskPage(
        projectId: project.remoteId,
        cwd: project.remoteId == null ? project.cwd : null,
        cursor: cursor,
      );

  Future<T> _withProjectSync<T>(
    CodexRemoteApi api,
    int epoch,
    Future<T> Function(SharedProjectSync sync) action,
  ) {
    final hostId = _selectedHostId!;
    final attempt = _connectionAttempt;
    void check() => _ensureCurrentSession(api, attempt, epoch, hostId);
    if (_projectOperationApi != api) {
      _projectOperationApi = api;
      _projectOperation = Future.value();
    }
    final result = _projectOperation.then((_) async {
      check();
      final value = await action(SharedProjectSync(api, _store, hostId, check));
      check();
      return value;
    });
    _projectOperation =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void _replaceSharedProjects(List<RemoteProject> projects) {
    final previous = selectedProject;
    _projects = List.unmodifiable(projects);
    if (!_projects.any((project) => project.id == _selectedProjectId)) {
      _selectedProjectId = _projects
              .where((project) =>
                  previous != null && project.containsCwd(previous.cwd))
              .firstOrNull
              ?.id ??
          _projects.firstOrNull?.id;
      _taskCatalog.clearProjectPage();
    }
  }

  Future<void> _syncSharedProjects(CodexRemoteApi api, int epoch) async {
    if (_unsupportedProjectsApi == api) return;
    try {
      await _withProjectSync<void>(api, epoch, (sync) async {
        final projects = await sync.synchronize();
        sync.checkSession();
        _sharedProjectsApi = api;
        _replaceSharedProjects(projects);
      });
    } on RpcRemoteException catch (error) {
      if (api != _api || epoch != _epoch) return;
      if (error.code == -32601) {
        _unsupportedProjectsApi = api;
      } else {
        _error = 'Project sync failed: ${_friendlyError(error)}';
      }
    } catch (error) {
      if (api != _api || epoch != _epoch) return;
      _error = 'Project sync failed: ${_friendlyError(error)}';
    }
  }

  Future<void> saveProject({
    String? projectId,
    required String name,
    required String cwd,
  }) async {
    final hostId = _selectedHostId;
    if (hostId == null) throw StateError('Connect to a host first.');
    final normalizedName = name.trim();
    final normalizedCwd = normalizeRemoteCwd(cwd);
    if (normalizedName.isEmpty || normalizedCwd.isEmpty) {
      throw ArgumentError('Project name and remote directory are required.');
    }
    if (!normalizedCwd.startsWith('/')) {
      throw ArgumentError('Use an absolute remote directory path.');
    }
    final api = _requireApi();
    final epoch = _epoch;
    if (_unsupportedProjectsApi == api) {
      throw StateError('Update remote Codex to enable shared projects.');
    }
    final previous =
        _projects.where((project) => project.id == projectId).firstOrNull;
    await _withProjectSync<void>(api, epoch, (sync) async {
      final shared = await sync.synchronize();
      sync.checkSession();
      final byId =
          shared.where((project) => project.id == projectId).firstOrNull;
      if (previous?.remoteId != null && byId == null) {
        throw StateError(
            'This project was deleted on another client. Refresh the list.');
      }
      final byPath = shared
          .where((project) => project.containsCwd(normalizedCwd))
          .toList();
      final existing = byId ?? (byPath.length == 1 ? byPath.single : null);
      final draft =
          existing?.copyWith(name: normalizedName, cwd: normalizedCwd) ??
              RemoteProject(
                id: previous?.id ??
                    '$hostId-${DateTime.now().microsecondsSinceEpoch}',
                hostId: hostId,
                name: normalizedName,
                cwd: normalizedCwd,
              );
      // Persist an unsynced draft first so a lost create response can be retried.
      if (existing == null) await _store.writeProject(draft);
      sync.checkSession();
      final saved = existing == null
          ? await api.createProject(draft)
          : await api.updateProject(draft);
      sync.checkSession();
      if (existing == null) {
        await sync.adoptUnassignedTasks(saved, cwd: normalizedCwd);
      }
      await _store.writeProject(saved);
      sync.checkSession();
      if (draft.remoteId == null) await _store.deleteProject(hostId, draft.id);
      sync.checkSession();
      _sharedProjectsApi = api;
      _replaceSharedProjects([
        for (final project in shared)
          if (project.remoteId != saved.remoteId) project,
        saved,
      ]);
      _selectedProjectId = saved.id;
    });
    _selectedTaskId = null;
    _historyLoadState.clear();
    _taskCatalog.clearProjectPage();
    notifyListeners();
    await refreshTasks(resetPages: true);
  }

  Future<void> deleteProject(String projectId) async {
    final hostId = _selectedHostId;
    if (hostId == null) return;
    final api = _requireApi();
    await _withProjectSync<void>(api, _epoch, (sync) async {
      final project = _projects.where((p) => p.id == projectId).firstOrNull;
      if (project == null) return;
      if (project.remoteId != null) await api.deleteProject(project.remoteId!);
      sync.checkSession();
      await _store.deleteProject(hostId, projectId);
      sync.checkSession();
      _projects = _projects.where((p) => p.id != projectId).toList();
    });
    if (_selectedProjectId == projectId) {
      _selectedProjectId = _projects.firstOrNull?.id;
      _selectedTaskId = null;
      _historyLoadState.clear();
      _taskCatalog.clearProjectPage();
    }
    notifyListeners();
    await refreshTasks(resetPages: true);
  }

  void toggleUnassigned() {
    _taskCatalog.toggleUnassigned();
    notifyListeners();
  }

  Future<void> loadMoreProjectTasks() async {
    final api = _api;
    final project = selectedProject;
    final continuation = _taskCatalog.projectContinuation;
    final epoch = _epoch;
    if (api == null ||
        !isConnected ||
        project == null ||
        continuation == null ||
        _loadingProjectPage) {
      return;
    }
    final pageToken = _taskReducer.capturePageMerge(epoch);
    final generation = ++_projectPageGeneration;
    _loadingProjectPage = true;
    notifyListeners();
    try {
      final page = await _readProjectTasks(
        api,
        project,
        cursor: continuation.cursor,
      );
      if (api != _api ||
          epoch != _epoch ||
          generation != _projectPageGeneration ||
          project.id != _selectedProjectId) {
        return;
      }
      if (!_taskCatalog.isCurrentProjectContinuation(continuation)) return;
      final applied = _taskReducer.applyPageMerge(
        pageToken,
        page.tasks,
        _interactiveThreadIds,
      );
      if (!applied) return;
      _taskCatalog.appendProjectPage(
        continuation,
        page.tasks,
        nextCursor: page.nextCursor,
      );
    } catch (exception) {
      if (api == _api &&
          epoch == _epoch &&
          generation == _projectPageGeneration) {
        _error = _friendlyError(exception);
      }
    } finally {
      if (generation == _projectPageGeneration) {
        _loadingProjectPage = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMoreRecentTasks() async {
    final api = _api;
    final continuation = _taskCatalog.recentContinuation;
    final epoch = _epoch;
    if (api == null ||
        !isConnected ||
        continuation == null ||
        _loadingRecentPage) {
      return;
    }
    final pageToken = _taskReducer.capturePageMerge(epoch);
    _loadingRecentPage = true;
    notifyListeners();
    try {
      final page = await api.readTaskPage(cursor: continuation.cursor);
      if (api != _api || epoch != _epoch) return;
      if (!_taskCatalog.isCurrentRecentContinuation(continuation)) return;
      _discoverProjects(page.tasks);
      final applied = _taskReducer.applyPageMerge(
        pageToken,
        page.tasks,
        _interactiveThreadIds,
      );
      if (!applied) return;
      _taskCatalog.appendRecentPage(
        continuation,
        page.tasks,
        nextCursor: page.nextCursor,
      );
    } catch (exception) {
      if (api == _api && epoch == _epoch) {
        _error = _friendlyError(exception);
      }
    } finally {
      if (api == _api && epoch == _epoch) {
        _loadingRecentPage = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMoreUnassignedTasks() async {
    final api = _api;
    final continuation = _taskCatalog.unassignedContinuation;
    final epoch = _epoch;
    if (api == null ||
        !isConnected ||
        continuation == null ||
        _loadingUnassignedPage) {
      return;
    }
    final pageToken = _taskReducer.capturePageMerge(epoch);
    _loadingUnassignedPage = true;
    notifyListeners();
    try {
      final page = await api.readTaskPage(cursor: continuation.cursor);
      if (api != _api || epoch != _epoch) return;
      if (!_taskCatalog.isCurrentUnassignedContinuation(continuation)) return;
      _discoverProjects(page.tasks);
      final applied = _taskReducer.applyPageMerge(
        pageToken,
        page.tasks,
        _interactiveThreadIds,
      );
      if (!applied) return;
      _taskCatalog.appendUnassignedPage(
        continuation,
        page.tasks,
        projects: _projects,
        nextCursor: page.nextCursor,
      );
    } catch (exception) {
      _error = _friendlyError(exception);
    } finally {
      _loadingUnassignedPage = false;
      notifyListeners();
    }
  }

  void _discoverProjects(Iterable<TaskSnapshot> tasks) {
    for (final task in tasks) {
      final cwd = normalizeRemoteCwd(task.cwd);
      if (cwd.isEmpty) continue;
      final current = _projectActivityByCwd[cwd];
      if (current == null || task.updatedAt.isAfter(current)) {
        _projectActivityByCwd[cwd] = task.updatedAt;
      }
    }
    _discoverProjectCwds(tasks.map((task) => task.cwd));
  }

  bool _discoverProjectCwds(Iterable<String> cwds) {
    if (_sharedProjectsApi == _api && _api != null) return false;
    final hostId = _selectedHostId;
    if (hostId == null) return false;
    final projects = mergeRemoteProjects(
      hostId: hostId,
      existing: _projects,
      discoveredCwds: cwds,
      activityByCwd: _projectActivityByCwd,
    );
    if (listEquals(projects, _projects)) return false;
    _projects = projects;
    if (_selectedProjectId == null ||
        !_projects.any((project) => project.id == _selectedProjectId)) {
      _selectedProjectId = _projects.firstOrNull?.id;
      _taskCatalog.clearProjectPage();
    }
    return true;
  }

  void _startProjectDiscovery(
    CodexRemoteApi api, {
    required int attempt,
    required int epoch,
    required String profileId,
  }) {
    if (_sharedProjectsApi == api) return;
    if (identical(_projectDiscoveryApi, api)) return;
    _projectDiscoveryApi = api;
    unawaited(_discoverAllProjects(
      api,
      attempt: attempt,
      epoch: epoch,
      profileId: profileId,
    ));
  }

  Future<void> _discoverAllProjects(
    CodexRemoteApi api, {
    required int attempt,
    required int epoch,
    required String profileId,
  }) async {
    try {
      final activity = await api.readProjectActivity();
      if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
      for (final entry in activity.entries) {
        final cwd = normalizeRemoteCwd(entry.key);
        final current = _projectActivityByCwd[cwd];
        if (current == null || entry.value.isAfter(current)) {
          _projectActivityByCwd[cwd] = entry.value;
        }
      }
      if (!_discoverProjectCwds(activity.keys)) return;
      notifyListeners();
      await refreshTasks(resetPages: true);
    } catch (exception) {
      if (_isCurrentSession(api, attempt, epoch, profileId)) {
        debugPrint('Could not discover remote projects: $exception');
      }
    }
  }

  Future<void> startNewTask({
    required String cwd,
    required String prompt,
    String? projectId,
    String? model,
    String? effort,
    String? serviceTier,
  }) async {
    final api = _requireApi();
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    final profileId = _selectedHostId!;
    final project = _projects.where((p) => p.id == projectId).firstOrNull;
    if (projectId != null && project == null) {
      throw StateError('The project was removed. Refresh the project list.');
    }
    final threadId =
        await api.startThread(cwd: cwd, projectId: project?.remoteId);
    if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
    _subscribedThreadIds = {..._subscribedThreadIds, threadId};
    draftForTask(threadId).settings = TurnSettings(
      model: model,
      effort: effort,
      serviceTier: serviceTier ?? 'default',
    );
    _selectedTaskId = threadId;
    _taskReducer.applyEvent(
      _epoch,
      TaskEvent.statusChanged(threadId, TaskStatus.running),
    );
    notifyListeners();
    await api.startTurn(
      threadId,
      prompt,
      model: model,
      effort: effort,
      serviceTier: serviceTier,
    );
    if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
    _taskReducer.setTurnSettings(epoch, threadId, model, effort);
    await refreshTasks();
  }

  Future<Uint8List> loadAttachmentImage(String path) async {
    final ssh = _ssh;
    final attempt = _connectionAttempt;
    if (ssh == null) throw StateError('SSH is disconnected');
    final bytes = await readAttachmentImage(ssh.client, path);
    if (!identical(ssh, _ssh) || attempt != _connectionAttempt) {
      throw StateError('Connection changed');
    }
    return bytes;
  }

  Future<RemoteAttachment> uploadAttachmentNow(
    LocalAttachment attachment,
    AttachmentUploadTarget target,
    AttachmentUploadCancellation cancellation, {
    void Function(int acknowledged, int total)? onProgress,
  }) async {
    final profile = selectedHost;
    if (profile == null) throw StateError('Select an SSH host first.');
    final profileId = profile.id;
    final secret = await _store.readSecret(profileId);
    final result = await uploadAttachmentResumable(
      attachment: attachment,
      target: target,
      cancellation: cancellation,
      onProgress: onProgress,
      onRetry: (retry, acknowledged, error) =>
          Diagnostics.record('attachment.uploadRetry', {
        'retry': retry,
        'acknowledgedBytes': acknowledged,
        ...Diagnostics.errorFields(error),
      }),
      connect: () async {
        cancellation.check();
        if (_selectedHostId != profileId) {
          throw StateError('Selected host changed during attachment upload.');
        }
        final connection = await _connector.connect(
          profile,
          secret,
          prompt: (_) async => false,
          diagnosticAttempt: _connectionAttempt,
          diagnosticRole: 'attachment-upload',
        );
        if (cancellation.isCancelled || _selectedHostId != profileId) {
          await connection.close(reason: 'attachment_upload_cancelled');
          cancellation.check();
          throw StateError('Selected host changed during attachment upload.');
        }
        return SftpAttachmentUploadSession.open(connection, target);
      },
    );
    if (_selectedHostId != profileId) {
      throw StateError('Selected host changed during attachment upload.');
    }
    return result;
  }

  bool _downloadingFile = false;
  DownloadCancellation? _downloadCancellation;

  void cancelDownload() {
    final cancellation = _downloadCancellation;
    if (cancellation == null || cancellation.isCancelled) return;
    Diagnostics.record('download.cancelRequested');
    cancellation.cancel();
  }

  Future<bool> downloadFile(String link,
      {void Function(downloads.DownloadProgress)? onProgress}) async {
    if (_downloadingFile) throw StateError('A download is already active');
    if (!Attachments.supported) throw UnsupportedError('Android download only');
    final ssh = _ssh;
    final profile = selectedHost;
    final path = downloads.remoteFilePath(link, selectedTask?.cwd ?? '');
    if (ssh == null || profile == null || path == null) {
      throw StateError('Remote file unavailable');
    }
    _downloadingFile = true;
    final cancellation = DownloadCancellation();
    _downloadCancellation = cancellation;
    Directory? temporary;
    var stage = 'temporary_storage';
    try {
      final cache =
          await Attachments.channel.invokeMethod<String>('downloadDirectory');
      if (cache == null) throw StateError('No download directory');
      temporary = await Directory(cache).createTemp('codex-download-');
      final file = File('${temporary.path}/payload.bin');
      stage = 'ssh_transfer';
      final secret = await _store.readSecret(profile.id);
      await downloadResumableFile(
        destination: file,
        cancellation: cancellation,
        connect: () async {
          cancellation.check();
          final connection = await _connector.connect(profile, secret,
              prompt: (_) async => false, diagnosticRole: 'download');
          if (cancellation.isCancelled) {
            await connection.close(reason: 'download_cancelled');
            throw DownloadCancelled();
          }
          return SftpDownloadSource.open(connection, path);
        },
        onProgress: onProgress,
        onRetry: (retry, received, error) =>
            Diagnostics.record('download.retry', {
          'retry': retry,
          'receivedBytes': received,
          ...Diagnostics.errorFields(error),
        }),
      );
      cancellation.check();
      stage = 'phone_save';
      onProgress?.call(downloads.DownloadProgress(
          await file.length(), await file.length(),
          saving: true));
      return await Attachments.channel.invokeMethod<bool>('saveDownload', {
            'path': file.path,
            'name': path.split('/').last,
          }) ??
          false;
    } catch (error) {
      Diagnostics.record('download.failed', {
        'stage': stage,
        if (error is downloads.FileDownloadException) ...{
          'transferStage': error.stage,
          'receivedBytes': error.received,
          'exitCode': error.exitCode,
        },
        ...Diagnostics.errorFields(error is downloads.FileDownloadException
            ? error.cause ?? error
            : error),
      });
      rethrow;
    } finally {
      try {
        await temporary?.delete(recursive: true);
      } finally {
        _downloadingFile = false;
        _downloadCancellation = null;
      }
    }
  }

  Future<TaskMessageDisposition> sendPrompt(
    String prompt, {
    TaskSendMode mode = TaskSendMode.auto,
    RemoteSkill? skill,
    String? model,
    String? effort,
    String? serviceTier,
    List<RemoteAttachment> attachments = const [],
  }) async {
    final api = _api;
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    final profileId = _selectedHostId;
    if (profileId == null) throw StateError('Select a host first.');
    if (!isConnected && mode == TaskSendMode.steer) {
      throw StateError(
          'Reconnect to steer the active turn. Use Queue while offline.');
    }
    var task = selectedTask;
    if (task == null) throw StateError('Select or create a task first.');
    task = _taskReducer.state.tasks[task.id] ?? task;
    final normalized = attachmentPrompt(prompt, attachments);
    if (normalized.isEmpty) throw ArgumentError('Message is required.');
    final pending = QueuedTaskMessage(
      id: 'queued-${DateTime.now().microsecondsSinceEpoch}-${_nextQueuedMessageId++}',
      text: skill == null ? normalized : '\$${skill.name} $normalized',
      skill: skill,
      model: model,
      effort: effort,
      serviceTier: serviceTier,
      imagePaths: List.unmodifiable(
          attachments.where((file) => file.isImage).map((file) => file.path)),
    );
    if (!isConnected ||
        api == null ||
        mode == TaskSendMode.queue ||
        (mode == TaskSendMode.auto && _messageQueue.hasPending(task.id))) {
      await _enqueuePrompt(task.id, pending);
      return TaskMessageDisposition.queued;
    }

    var activeTurnId = _activeTurnIds[task.id];
    if (mode == TaskSendMode.steer ||
        (activeTurnId == null &&
            (task.status == TaskStatus.running ||
                task.status == TaskStatus.queued))) {
      activeTurnId = await api.readActiveTurnId(task.id);
      _ensureCurrentSession(api, attempt, epoch, profileId);
      if (activeTurnId != null) {
        _activeTurnIds[task.id] = activeTurnId;
      } else {
        _activeTurnIds.remove(task.id);
      }
    }
    final route = mode == TaskSendMode.auto
        ? chooseTaskMessageRoute(
            task.status,
            activeTurnId: activeTurnId,
          )
        : chooseExplicitMessageRoute(mode, activeTurnId: activeTurnId);
    switch (route) {
      case TaskMessageRoute.steer:
        return _steerPrompt(
          task,
          pending,
          activeTurnId!,
          api: api,
          attempt: attempt,
          epoch: epoch,
          profileId: profileId,
          queueIfFinished: mode != TaskSendMode.steer,
        );
      case TaskMessageRoute.queue:
        await _enqueuePrompt(task.id, pending);
        return TaskMessageDisposition.queued;
      case TaskMessageRoute.start:
        await _startPendingPrompt(task, pending);
        return TaskMessageDisposition.started;
    }
  }

  Future<TaskMessageDisposition> _steerPrompt(
    TaskRecord task,
    QueuedTaskMessage pending,
    String turnId, {
    required CodexRemoteApi api,
    required int attempt,
    required int epoch,
    required String profileId,
    bool queueIfFinished = true,
  }) async {
    _setLocalUserMessageStatus(task.id, pending, 'sending', epoch: epoch);
    var steerRequested = false;
    try {
      if (requiresThreadResumeForSteer(
        subscribed: _subscribedThreadIds.contains(task.id),
      )) {
        await _ensureThreadSubscribed(
          task.id,
          api: api,
          attempt: attempt,
          epoch: epoch,
          profileId: profileId,
        );
      }
      try {
        await _journalPrompt(profileId, task.id, pending);
        _ensureCurrentSession(api, attempt, epoch, profileId);
        steerRequested = true;
        await api.steerTurn(task.id, turnId, pending.text,
            imagePaths: pending.imagePaths);
        await _settlePrompt(profileId, task.id, pending, 'sent');
      } on RpcRemoteException {
        steerRequested = false;
        final refreshedTurnId = await api.readActiveTurnId(task.id);
        _ensureCurrentSession(api, attempt, epoch, profileId);
        if (refreshedTurnId == null) {
          _activeTurnIds.remove(task.id);
          if (!queueIfFinished) {
            throw StateError('The turn finished before Steer was accepted. '
                'Use Auto to start a new turn.');
          }
          _setLocalUserMessageStatus(
            task.id,
            pending,
            'queued',
            epoch: epoch,
          );
          await _enqueuePrompt(task.id, pending);
          return TaskMessageDisposition.queued;
        }
        if (refreshedTurnId == turnId) rethrow;
        _activeTurnIds[task.id] = refreshedTurnId;
        steerRequested = true;
        await api.steerTurn(task.id, refreshedTurnId, pending.text,
            imagePaths: pending.imagePaths);
        await _settlePrompt(profileId, task.id, pending, 'sent');
      }
      _recordSubmittedPrompt(
        task.id,
        pending,
        api: api,
        attempt: attempt,
        epoch: epoch,
        profileId: profileId,
      );
      return TaskMessageDisposition.steered;
    } catch (exception) {
      if (steerRequested && _isUncertainSubmissionFailure(exception)) {
        await _settlePrompt(profileId, task.id, pending, 'uncertain');
        _setLocalUserMessageStatus(task.id, pending, 'uncertain', epoch: epoch);
        return TaskMessageDisposition.queued;
      }
      _setLocalUserMessageStatus(task.id, pending, 'failed', epoch: epoch);
      await _settlePrompt(profileId, task.id, pending, 'sent');
      rethrow;
    }
  }

  Future<void> _enqueuePrompt(
      String threadId, QueuedTaskMessage pending) async {
    _captureSubmittedDraft(_selectedHostId!, threadId);
    if (!_messageQueue.values(threadId).contains(pending)) {
      _messageQueue.enqueue(threadId, pending);
    }
    _deliveryStates[pending.id] = 'queued';
    try {
      await _saveWorkspace();
    } catch (_) {
      _messageQueue.remove(threadId, pending);
      _deliveryStates.remove(pending.id);
      rethrow;
    }
    notifyListeners();
    unawaited(_flushQueuedPrompt(threadId));
  }

  Future<void> _journalPrompt(
      String host, String task, QueuedTaskMessage pending) async {
    _captureSubmittedDraft(host, task);
    final queue = _outboxes.putIfAbsent(host, TaskMessageQueue.new);
    if (!queue.values(task).contains(pending)) queue.enqueue(task, pending);
    _deliveryStates[pending.id] = 'sending';
    _markQueuedMessageInFlight(task, pending.id);
    await _saveWorkspace();
  }

  Future<void> _settlePrompt(
      String host, String task, QueuedTaskMessage pending, String state) async {
    _unmarkQueuedMessageInFlight(task, pending.id);
    if (state == 'sent') {
      _outboxes[host]?.remove(task, pending);
      _deliveryStates.remove(pending.id);
    } else {
      _deliveryStates[pending.id] = state;
    }
    try {
      await _saveWorkspace();
    } catch (error) {
      _error =
          'Could not save delivery status. Check conversation before retrying: $error';
    }
    if (!_disposed) notifyListeners();
  }

  void _captureSubmittedDraft(String host, String task) {
    final draft = _drafts[(host, task)];
    if (draft != null && draft.sending) {
      _savedDrafts[(host, task)] = draft.toJson();
    }
  }

  Future<void> retryQueuedMessage(String taskId, String messageId) async {
    final pending = _messageQueue
        .values(taskId)
        .where((message) => message.id == messageId)
        .firstOrNull;
    if (pending == null || _deliveryStates[messageId] == 'sending') return;
    _requireApi();
    _deliveryStates[messageId] = 'queued';
    await _saveWorkspace();
    await _flushQueuedPrompt(taskId);
    notifyListeners();
  }

  Future<void> _startPendingPrompt(
    TaskRecord task,
    QueuedTaskMessage pending, {
    bool keepOnFailure = false,
  }) async {
    final api = _requireApi();
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    final profileId = _selectedHostId!;
    _setLocalUserMessageStatus(task.id, pending, 'sending', epoch: epoch);
    var turnRequested = false;
    try {
      if (requiresThreadResumeForSend(
        subscribed: _subscribedThreadIds.contains(task.id),
      )) {
        await _ensureThreadSubscribed(
          task.id,
          api: api,
          attempt: attempt,
          epoch: epoch,
          profileId: profileId,
        );
      }
      await _journalPrompt(profileId, task.id, pending);
      _ensureCurrentSession(api, attempt, epoch, profileId);
      turnRequested = true;
      await api.startTurn(
        task.id,
        pending.text,
        skill: pending.skill,
        model: pending.model,
        effort: pending.effort,
        serviceTier: pending.serviceTier,
        imagePaths: pending.imagePaths,
      );
      await _settlePrompt(profileId, task.id, pending, 'sent');
      if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
      _taskReducer.setTurnSettings(
          epoch, task.id, pending.model, pending.effort);
      _recordSubmittedPrompt(
        task.id,
        pending,
        api: api,
        attempt: attempt,
        epoch: epoch,
        profileId: profileId,
      );
    } catch (exception) {
      if (turnRequested && _isUncertainSubmissionFailure(exception)) {
        await _settlePrompt(profileId, task.id, pending, 'uncertain');
        _setLocalUserMessageStatus(task.id, pending, 'uncertain', epoch: epoch);
        return;
      }
      _setLocalUserMessageStatus(task.id, pending, 'failed', epoch: epoch);
      await _settlePrompt(
          profileId, task.id, pending, keepOnFailure ? 'failed' : 'sent');
      rethrow;
    }
  }

  void _setLocalUserMessageStatus(
    String threadId,
    QueuedTaskMessage pending,
    String status, {
    required int epoch,
  }) {
    if (_disposed) return;
    if (status == 'sending') {
      _taskReducer.appendPendingUserMessage(
        epoch,
        threadId,
        pending.timelineItemId,
        pending.text,
      );
    } else {
      _taskReducer.updatePendingUserMessageStatus(
        epoch,
        threadId,
        pending.timelineItemId,
        status,
      );
    }
    notifyListeners();
  }

  void _recordSubmittedPrompt(
    String threadId,
    QueuedTaskMessage pending, {
    required CodexRemoteApi api,
    required int attempt,
    required int epoch,
    required String profileId,
  }) {
    if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
    _setLocalUserMessageStatus(threadId, pending, 'sent', epoch: epoch);
    _interactiveThreadIds.add(threadId);
    _taskReducer.markLocalParticipation(epoch, threadId);
    _taskReducer.applyEvent(
      epoch,
      TaskEvent.statusChanged(threadId, TaskStatus.running),
    );
    notifyListeners();
    unawaited(_catchUpTaskContext(
      threadId,
      api: api,
      attempt: attempt,
      epoch: epoch,
      profileId: profileId,
    ));
  }

  Future<void> _recoverSelectedTaskAfterReconnect(
    CodexRemoteApi api, {
    required int attempt,
    required int epoch,
    required String profileId,
  }) async {
    final threadId = _selectedTaskId;
    if (threadId == null) return;
    await _loadInitialTaskContext(threadId);
    if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
    await _catchUpTaskContext(
      threadId,
      api: api,
      attempt: attempt,
      epoch: epoch,
      profileId: profileId,
      readItems: false,
    );
  }

  Future<void> _catchUpTaskContext(
    String threadId, {
    required CodexRemoteApi api,
    required int attempt,
    required int epoch,
    required String profileId,
    bool readItems = true,
  }) async {
    if (readItems) {
      try {
        _agentDeltaBatcher.flush();
        final readToken = _taskReducer.captureItemsRead(epoch, threadId);
        final page = await api.readThreadTurnsPage(threadId);
        if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
        _agentDeltaBatcher.flush();
        _taskReducer.mergeLatestItems(epoch, threadId, page.items,
            readToken: readToken);
        if (_selectedTaskId == threadId &&
            _historyLoadState.taskId != threadId) {
          final token = _historyLoadState.beginInitial(threadId);
          _historyLoadState.complete(token, nextCursor: page.nextCursor);
        }
        notifyListeners();
      } catch (exception) {
        debugPrint('Could not catch up selected task context: $exception');
      }
    }
    try {
      final activeTurnId = await api.readActiveTurnId(threadId);
      if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
      if (activeTurnId == null) {
        _activeTurnIds.remove(threadId);
      } else {
        _activeTurnIds[threadId] = activeTurnId;
      }
      notifyListeners();
    } catch (exception) {
      debugPrint('Could not refresh selected task turn state: $exception');
    }
  }

  Future<void> _flushQueuedPrompt(String threadId) async {
    final operation = _messageOperations.tryAcquire(threadId);
    if (operation == null) return;
    try {
      final pending = _messageQueue.peek(threadId);
      final task = _taskReducer.state.tasks[threadId];
      if (pending == null ||
          task == null ||
          !isConnected ||
          (_deliveryStates[pending.id] != null &&
              _deliveryStates[pending.id] != 'queued')) {
        return;
      }
      String? activeTurnId;
      var activeTurnChecked = false;
      {
        final api = _requireApi();
        final attempt = _connectionAttempt;
        final epoch = _epoch;
        final profileId = _selectedHostId!;
        activeTurnId = await api.readActiveTurnId(threadId);
        _ensureCurrentSession(api, attempt, epoch, profileId);
        activeTurnChecked = true;
        if (activeTurnId == null) {
          _activeTurnIds.remove(threadId);
        } else {
          _activeTurnIds[threadId] = activeTurnId;
        }
      }
      if (chooseQueuedPromptAction(
            task.status,
            activeTurnId: activeTurnId,
            activeTurnChecked: activeTurnChecked,
          ) ==
          QueuedPromptAction.wait) {
        return;
      }
      _markQueuedMessageInFlight(threadId, pending.id);
      try {
        await _startPendingPrompt(task, pending, keepOnFailure: true);
      } finally {
        _unmarkQueuedMessageInFlight(threadId, pending.id);
      }
    } catch (exception) {
      _error = _friendlyError(exception);
      notifyListeners();
    } finally {
      _messageOperations.release(threadId, operation);
    }
  }

  void _flushReadyQueuedPrompts() {
    for (final threadId in _messageQueue.threadIds) {
      if (!_taskReducer.state.tasks.containsKey(threadId)) {
        _taskReducer.applyEvent(
            _epoch, TaskEvent.statusChanged(threadId, TaskStatus.unknown));
      }
      unawaited(_flushQueuedPrompt(threadId));
    }
  }

  void _markQueuedMessageInFlight(String threadId, String messageId) {
    final ids = _inFlightQueuedMessageIds.putIfAbsent(threadId, () => {});
    if (ids.add(messageId) && !_disposed) notifyListeners();
  }

  void _unmarkQueuedMessageInFlight(String threadId, String messageId) {
    final ids = _inFlightQueuedMessageIds[threadId];
    if (ids == null || !ids.remove(messageId)) return;
    if (ids.isEmpty) _inFlightQueuedMessageIds.remove(threadId);
    if (!_disposed) notifyListeners();
  }

  Future<void> removeQueuedMessage(String taskId, String messageId) async {
    if (_deliveryStates[messageId] == 'sending') {
      throw StateError('This message is already being sent.');
    }
    final operation = _messageOperations.tryAcquire(taskId);
    if (operation == null) {
      throw StateError('A queued message is already being sent.');
    }
    try {
      final pending = _messageQueue
          .values(taskId)
          .where((message) => message.id == messageId)
          .firstOrNull;
      if (pending != null && _messageQueue.remove(taskId, pending)) {
        _deliveryStates.remove(pending.id);
        await _saveWorkspace();
        notifyListeners();
      }
    } finally {
      _messageOperations.release(taskId, operation);
    }
  }

  Future<void> steerQueuedMessage(String taskId, String messageId) async {
    if (_deliveryStates[messageId] == 'sending' ||
        _deliveryStates[messageId] == 'uncertain') {
      throw StateError('Check delivery before sending this message again.');
    }
    final operation = _messageOperations.tryAcquire(taskId);
    if (operation == null) {
      throw StateError('A queued message is already being sent.');
    }
    try {
      final pending = _messageQueue
          .values(taskId)
          .where((message) => message.id == messageId)
          .firstOrNull;
      if (pending == null) return;
      final api = _requireApi();
      final attempt = _connectionAttempt;
      final epoch = _epoch;
      final profileId = _selectedHostId!;
      var turnId = _activeTurnIds[taskId];
      if (turnId == null) {
        turnId = await api.readActiveTurnId(taskId);
        _ensureCurrentSession(api, attempt, epoch, profileId);
        if (turnId != null) _activeTurnIds[taskId] = turnId;
      }
      if (turnId == null) {
        throw StateError('This task does not have an active turn to steer.');
      }
      _markQueuedMessageInFlight(taskId, pending.id);
      _setLocalUserMessageStatus(taskId, pending, 'sending', epoch: epoch);
      var steerRequested = false;
      try {
        if (requiresThreadResumeForSteer(
          subscribed: _subscribedThreadIds.contains(taskId),
        )) {
          await _ensureThreadSubscribed(
            taskId,
            api: api,
            attempt: attempt,
            epoch: epoch,
            profileId: profileId,
          );
        }
        try {
          await _journalPrompt(profileId, taskId, pending);
          _ensureCurrentSession(api, attempt, epoch, profileId);
          steerRequested = true;
          await api.steerTurn(taskId, turnId, pending.text,
              imagePaths: pending.imagePaths);
          await _settlePrompt(profileId, taskId, pending, 'sent');
        } on RpcRemoteException {
          steerRequested = false;
          final refreshedTurnId = await api.readActiveTurnId(taskId);
          _ensureCurrentSession(api, attempt, epoch, profileId);
          if (refreshedTurnId == null) {
            _activeTurnIds.remove(taskId);
            throw StateError(
              'This task no longer has an active turn to steer.',
            );
          }
          if (refreshedTurnId == turnId) rethrow;
          _activeTurnIds[taskId] = refreshedTurnId;
          steerRequested = true;
          await api.steerTurn(taskId, refreshedTurnId, pending.text,
              imagePaths: pending.imagePaths);
          await _settlePrompt(profileId, taskId, pending, 'sent');
        }
        _recordSubmittedPrompt(
          taskId,
          pending,
          api: api,
          attempt: attempt,
          epoch: epoch,
          profileId: profileId,
        );
        if (_messageQueue.remove(taskId, pending)) notifyListeners();
      } catch (exception) {
        if (steerRequested && _isUncertainSubmissionFailure(exception)) {
          await _settlePrompt(profileId, taskId, pending, 'uncertain');
          _setLocalUserMessageStatus(taskId, pending, 'uncertain',
              epoch: epoch);
          return;
        }
        await _settlePrompt(profileId, taskId, pending, 'failed');
        _setLocalUserMessageStatus(taskId, pending, 'queued', epoch: epoch);
        rethrow;
      }
    } finally {
      _unmarkQueuedMessageInFlight(taskId, messageId);
      _messageOperations.release(taskId, operation);
    }
  }

  Future<List<RemoteSkill>> listSkillsForSelectedTask() async {
    final cwd = selectedTask?.cwd.isNotEmpty == true
        ? selectedTask!.cwd
        : selectedProject?.cwd;
    if (cwd == null || cwd.isEmpty) {
      throw StateError('The selected task has no working directory.');
    }
    return _requireApi().listSkills(cwd);
  }

  Future<void> _refreshGoal(String taskId) async {
    final api = _api;
    final epoch = _epoch;
    if (api == null || !isConnected) return;
    final revision = _goalRevisions[taskId] ?? 0;
    try {
      final goal = await api.readThreadGoal(taskId);
      if (api != _api ||
          epoch != _epoch ||
          revision != (_goalRevisions[taskId] ?? 0)) {
        return;
      }
      _goals[taskId] = goal;
      notifyListeners();
    } catch (_) {
      // Older servers can omit goals; opening a conversation must still work.
    }
  }

  Future<RemoteThreadGoal?> readSelectedGoal() async {
    final task = selectedTask;
    if (task == null) throw StateError('Select a task first.');
    await _refreshGoal(task.id);
    return _goals[task.id];
  }

  Future<RemoteThreadGoal> setSelectedGoal({
    required String objective,
    int? tokenBudget,
  }) async {
    final task = selectedTask;
    if (task == null) throw StateError('Select a task first.');
    final normalizedObjective = objective.trim();
    if (normalizedObjective.isEmpty) {
      throw ArgumentError('Goal objective is required.');
    }
    if (tokenBudget != null && tokenBudget <= 0) {
      throw ArgumentError('Token budget must be positive.');
    }
    final api = _requireApi();
    final epoch = _epoch;
    final result = await api.setThreadGoal(
      task.id,
      objective: normalizedObjective,
      tokenBudget: tokenBudget,
      status: _goals[task.id]?.objective == normalizedObjective
          ? _goals[task.id]!.status
          : 'active',
    );
    if (api == _api && epoch == _epoch) {
      _goals[task.id] = result;
      notifyListeners();
    }
    return result;
  }

  Future<void> clearSelectedGoal() async {
    final task = selectedTask;
    if (task == null) throw StateError('Select a task first.');
    final api = _requireApi();
    final epoch = _epoch;
    await api.clearThreadGoal(task.id);
    if (api == _api && epoch == _epoch) {
      _goals.remove(task.id);
      notifyListeners();
    }
  }

  Future<void> setGoalPaused(bool paused) async {
    final id = _selectedTaskId;
    if (id == null) return;
    final api = _requireApi();
    final epoch = _epoch;
    final goal =
        await api.setThreadGoal(id, status: paused ? 'paused' : 'active');
    if (api != _api || epoch != _epoch) return;
    _goals[id] = goal;
    notifyListeners();
  }

  Future<RemoteTaskPage> findTasks(
      {String? query,
      String? cursor,
      bool archived = false,
      bool? pinned}) async {
    final api = _requireApi();
    final epoch = _epoch;
    final result = await api.readTaskPage(
        searchTerm: query,
        cursor: cursor,
        archived: archived,
        isPinned: pinned);
    if (api != _api || epoch != _epoch) throw StateError('Connection changed');
    return result;
  }

  Future<void> openFoundTask(TaskSnapshot task) async {
    _taskReducer.applySnapshot(_epoch, task, _interactiveThreadIds);
    await selectTask(task.id);
  }

  Future<void> renameTask(String id, String name) async {
    if (name.trim().isEmpty) throw ArgumentError('Name is required');
    final api = _requireApi();
    final epoch = _epoch;
    await api.renameThread(id, name.trim());
    if (api != _api || epoch != _epoch) return;
    _taskReducer.updateMetadata(epoch, id, title: name.trim());
    notifyListeners();
    await refreshTasks(resetPages: true);
  }

  Future<void> pinTask(String id, bool pinned) async {
    final api = _requireApi();
    final epoch = _epoch;
    await api.pinThread(id, pinned);
    if (api != _api || epoch != _epoch) return;
    _taskReducer.updateMetadata(epoch, id, isPinned: pinned);
    notifyListeners();
    await refreshTasks(resetPages: true);
  }

  Future<void> archiveTask(String id, bool archived) async {
    if (archived && _messageQueue.hasPending(id)) {
      throw StateError('Resolve queued messages before archiving this task.');
    }
    final api = _requireApi();
    final epoch = _epoch;
    await api.archiveThread(id, archived: archived);
    if (api != _api || epoch != _epoch) return;
    if (archived && _selectedTaskId == id) clearSelectedTask();
    // Rebuild catalog pages so a removed task cannot survive a head merge.
    await refreshTasks(resetPages: true);
  }

  Future<void> forkSelectedTask({String? turnId}) async {
    final task = selectedTask;
    if (task == null) return;
    final api = _requireApi();
    final epoch = _epoch;
    final fork = await api.forkThread(task.id, lastTurnId: turnId);
    if (api != _api || epoch != _epoch) return;
    _taskReducer.applySnapshot(epoch, fork, _interactiveThreadIds);
    await selectTask(fork.id);
    await refreshTasks();
  }

  Future<void> revertSelectedTask(String turnId) async {
    final task = selectedTask;
    if (task == null) return;
    final api = _requireApi();
    final epoch = _epoch;
    final attempt = _connectionAttempt;
    final host = _selectedHostId!;
    if (_messageQueue.hasPending(task.id)) {
      throw StateError('Resolve queued messages before reverting history.');
    }
    await _ensureThreadSubscribed(task.id,
        api: api, epoch: epoch, attempt: attempt, profileId: host);
    if (await api.readActiveTurnId(task.id) != null) {
      throw StateError('Stop the active turn before reverting history.');
    }
    _ensureCurrentSession(api, attempt, epoch, host);
    await api.revertThread(task.id, turnId);
    _ensureCurrentSession(api, attempt, epoch, host);
    _agentDeltaBatcher.clear();
    _taskReducer.replaceItems(epoch, task.id, const []);
    await _loadInitialTaskContext(task.id);
  }

  Future<void> compactSelectedTask() {
    final task = selectedTask;
    if (task == null) throw StateError('Select a task first.');
    return _requireApi().compactThread(task.id);
  }

  Future<void> interruptSelectedTask() async {
    final task = selectedTask;
    if (task == null) return;
    final api = _requireApi();
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    final profileId = _selectedHostId!;
    // Resolve the actual active turn even if it was started by another client.
    final turnId = await api.readActiveTurnId(task.id);
    _ensureCurrentSession(api, attempt, epoch, profileId);
    if (turnId == null) {
      _activeTurnIds.remove(task.id);
      await refreshTasks();
      return;
    }
    try {
      await api.interruptTurn(task.id, turnId);
    } finally {
      if (_isCurrentSession(api, attempt, epoch, profileId)) {
        unawaited(refreshTasks());
      }
    }
  }

  void answerApproval(PendingApproval approval, String decision) {
    if (!isConnected ||
        !_approvals.any((pending) => identical(pending, approval))) {
      return;
    }
    _api!.answerApproval(approval.requestId, decision);
    _approvals = _approvals
        .where((item) => item.requestId != approval.requestId)
        .toList(growable: false);
    notifyListeners();
  }

  Future<void> _ensureThreadSubscribed(
    String threadId, {
    required CodexRemoteApi api,
    required int attempt,
    required int epoch,
    required String profileId,
  }) async {
    _ensureCurrentSession(api, attempt, epoch, profileId);
    if (_subscribedThreadIds.contains(threadId)) return;
    final pending = _pendingThreadSubscriptions[threadId];
    if (pending != null) return pending;
    final operation = () async {
      final settings = await api.resumeThread(threadId);
      _ensureCurrentSession(api, attempt, epoch, profileId);
      _taskReducer.setTurnSettings(
          epoch, threadId, settings.model, settings.effort);
      _subscribedThreadIds = {..._subscribedThreadIds, threadId};
    }();
    _pendingThreadSubscriptions[threadId] = operation;
    try {
      await operation;
    } finally {
      if (identical(_pendingThreadSubscriptions[threadId], operation)) {
        unawaited(_pendingThreadSubscriptions.remove(threadId));
      }
    }
  }

  bool _isCurrentSession(
    CodexRemoteApi api,
    int attempt,
    int epoch,
    String profileId,
  ) =>
      identical(api, _api) &&
      attempt == _connectionAttempt &&
      epoch == _epoch &&
      profileId == _selectedHostId;

  void _ensureCurrentSession(
    CodexRemoteApi api,
    int attempt,
    int epoch,
    String profileId,
  ) {
    if (!_isCurrentSession(api, attempt, epoch, profileId)) {
      throw StateError('The remote connection changed while sending.');
    }
  }

  void _handleNotification(int attempt, RpcNotification notification) {
    if (attempt != _connectionAttempt) return;
    final method = notification.method;
    final params = notification.params;
    if (method == 'account/rateLimits/updated') {
      accountUsage.update(params);
      return;
    }
    if (method == 'account/updated') {
      accountUsage.bind(_api);
      unawaited(accountUsage.refresh());
      return;
    }
    if (method == 'thread/name/updated') {
      final id = params['threadId'] as String?;
      final name = params['threadName'] as String?;
      if (id != null && name != null) {
        _taskReducer.updateMetadata(_epoch, id, title: name);
        notifyListeners();
      }
    }
    if (method == 'thread/goal/updated' || method == 'thread/goal/cleared') {
      final id = params['threadId'] as String?;
      if (id != null) {
        _goalRevisions[id] = (_goalRevisions[id] ?? 0) + 1;
        _goals[id] = method.endsWith('/cleared')
            ? null
            : CodexRemoteApi.parseGoal(params['goal']);
        notifyListeners();
      }
      return;
    }
    if (method == 'project/changed' ||
        method == 'thread/project/updated' ||
        method == 'thread/name/updated' ||
        method == 'thread/metadata/updated' ||
        method == 'thread/archived' ||
        method == 'thread/unarchived') {
      _projectSyncTimer?.cancel();
      _projectSyncTimer = Timer(const Duration(milliseconds: 250), () {
        if (attempt == _connectionAttempt && isConnected) {
          unawaited(refreshTasks(resetPages: true));
        }
      });
    }
    if (method == 'thread/reverted') {
      final id = params['threadId'] as String?;
      if (id != null) {
        _agentDeltaBatcher.clear();
        _taskReducer.replaceItems(_epoch, id, const []);
        if (_selectedTaskId == id) unawaited(_loadInitialTaskContext(id));
      }
    }
    if (notification.method == 'serverRequest/resolved') {
      final id = notification.params['requestId'];
      final threadId = notification.params['threadId'];
      _userInputRequests = _userInputRequests
          .where((r) => r.id != id || r.threadId != threadId)
          .toList();
      _approvals = _approvals
          .where((r) => r.requestId != id || r.threadId != threadId)
          .toList();
      notifyListeners();
      return;
    }
    final event = CodexRemoteApi.parseNotification(
      notification.method,
      notification.params,
    );
    if (notification.method == 'item/agentMessage/delta' && event != null) {
      _agentDeltaBatcher.add(event);
      return;
    }
    if (notification.method == 'item/completed' ||
        notification.method == 'turn/completed') {
      _agentDeltaBatcher.flush();
    }
    if (event != null) _taskReducer.applyEvent(_epoch, event);
    final threadId = notification.params['threadId'] as String? ??
        (notification.params['thread'] is Map
            ? (notification.params['thread'] as Map)['id'] as String?
            : null);
    var activeTurnChanged = false;
    if (notification.method == 'turn/started') {
      final turn = notification.params['turn'];
      final turnId = turn is Map ? turn['id'] as String? : null;
      if (threadId != null && turnId != null) {
        activeTurnChanged = _activeTurnIds[threadId] != turnId;
        _activeTurnIds[threadId] = turnId;
      }
    } else if (notification.method == 'turn/completed' && threadId != null) {
      _interactiveThreadIds.remove(threadId);
      activeTurnChanged = _activeTurnIds.remove(threadId) != null;
      unawaited(refreshTasks());
      unawaited(_flushQueuedPrompt(threadId));
    }
    if (hasRemoteNotificationVisibleChange(
      event: event,
      activeTurnChanged: activeTurnChanged,
    )) {
      notifyListeners();
    }
  }

  void _applyAgentDeltaBatch(List<TaskEvent> events) {
    _taskReducer.applyEvents(_epoch, events);
    notifyListeners();
  }

  void _handleServerRequest(int attempt, RpcServerRequest request) {
    if (attempt != _connectionAttempt) return;
    if (request.method == 'item/tool/requestUserInput') {
      if (_userInputRequests.any((r) => r.id == request.id)) return;
      try {
        final input = UserInputRequest(request);
        _userInputRequests = [..._userInputRequests, input];
        notifyListeners();
      } catch (_) {
        _rpc?.respondError(request.id, -32602, 'Invalid user input request');
      }
      return;
    }
    if (!request.method.contains('requestApproval')) {
      _rpc?.respondError(request.id, -32601, 'Unsupported server request');
      return;
    }
    final approval = CodexRemoteApi.parseApproval(request);
    _approvals = [..._approvals, approval];
    notifyListeners();
  }

  CodexRemoteApi _requireApi() {
    final api = _api;
    if (api == null || !isConnected) {
      throw StateError('Connect to a host first.');
    }
    return api;
  }

  void answerUserInput(UserInputRequest request, Map<String, String> answers) {
    if (!isConnected || !_userInputRequests.any((r) => identical(r, request))) {
      return;
    }
    try {
      _rpc!.respond(request.id, request.response(answers));
    } catch (_) {
      _error = 'Could not send answers. Check the connection and retry.';
      notifyListeners();
      return;
    }
    _userInputRequests =
        _userInputRequests.where((r) => !identical(r, request)).toList();
    notifyListeners();
  }

  Future<void> disconnect() async {
    cancelDownload();
    Diagnostics.record('connection.userDisconnect');
    _expediteReconnect = false;
    _connectionAttempt++;
    _openingAttempt?.cancel(StateError('User disconnected'));
    final stoppingKeepAlive = _setKeepAlive(false);
    _cancelHostKeyPrompt();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _connectionPhase = RemoteConnectionPhase.disconnected;
    _loadingProjectPage = false;
    _loadingRecentPage = false;
    _loadingUnassignedPage = false;
    _projectPageGeneration++;
    _historyLoadState.clear();
    _activeTurnIds.clear();
    _messageOperations.clear();
    _inFlightQueuedMessageIds.clear();
    _subscribedThreadIds = {};
    _interactiveThreadIds.clear();
    _agentDeltaBatcher.clear();
    _epoch = _taskReducer.beginConnection(clearTasks: false);
    _approvals = const [];
    await _closeTransport(reason: 'user_disconnect');
    try {
      await _writeAutoConnectIntent(null);
    } catch (exception) {
      _error = 'Disconnected, but could not clear auto-connect: $exception';
    }
    await stoppingKeepAlive;
    notifyListeners();
  }

  Future<void> _rememberAutoConnectHost(String profileId) async {
    try {
      await _writeAutoConnectIntent(profileId);
    } catch (exception) {
      debugPrint('Could not remember auto-connect host: $exception');
    }
  }

  Future<void> _writeAutoConnectIntent(String? profileId) {
    final operation = _autoConnectIntentWrite.then(
      (_) => _store.writeAutoConnectHostId(profileId),
    );
    _autoConnectIntentWrite = operation.catchError((Object exception) {
      debugPrint('Could not persist auto-connect intent: $exception');
    });
    return operation;
  }

  List<TaskRecord> _tasksForIds(List<String> ids) => (ids
      .map((id) => _taskReducer.state.tasks[id])
      .whereType<TaskRecord>()
      .toList(growable: false))
    ..sort((a, b) => a.isPinned == b.isPinned
        ? b.updatedAt.compareTo(a.updatedAt)
        : a.isPinned
            ? -1
            : 1);

  Future<void> _closeTransport(
      {String reason = 'connection_replaced_or_closed'}) async {
    accountUsage.bind(null);
    _userInputRequests = const [];
    Diagnostics.record('connection.closeRequested', {'closeReason': reason});
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _agentDeltaBatcher.clear();
    _approvals = const [];
    _historyLoadState.cancelPending();
    _projectDiscoveryApi = null;
    _subscribedThreadIds = {};
    _pendingThreadSubscriptions.clear();
    _loadingProjectPage = false;
    _loadingRecentPage = false;
    _loadingUnassignedPage = false;
    _projectPageGeneration++;
    final notificationSubscription = _notificationSubscription;
    final requestSubscription = _requestSubscription;
    final rpc = _rpc;
    final tunnel = _tunnel;
    final ssh = _ssh;
    _notificationSubscription = null;
    _requestSubscription = null;
    _rpc = null;
    _api = null;
    _tunnel = null;
    _ssh = null;
    await Future.wait([
      if (notificationSubscription != null)
        boundedConnectionCleanup(
            'notifications', notificationSubscription.cancel),
      if (requestSubscription != null)
        boundedConnectionCleanup('requests', requestSubscription.cancel),
      if (rpc != null) boundedConnectionCleanup('rpc', rpc.close),
      if (tunnel != null) boundedConnectionCleanup('tunnel', tunnel.close),
      if (ssh != null)
        boundedConnectionCleanup('ssh', () => ssh.close(reason: reason)),
    ]);
  }

  void clearError() {
    _error = null;
    _keepAliveWarning = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _draftSaveTimer?.cancel();
    _projectSyncTimer?.cancel();
    unawaited(flushWorkspace().catchError((Object error) {
      debugPrint('Could not save workspace on close: $error');
    }));
    for (final draft in _drafts.values) {
      draft.dispose();
    }
    _drafts.clear();
    cancelDownload();
    _network.dispose();
    _connectionAttempt++;
    _openingAttempt?.cancel(StateError('Controller disposed'));
    _cancelHostKeyPrompt();
    _reconnectTimer?.cancel();
    _refreshTimer?.cancel();
    _agentDeltaBatcher.dispose();
    unawaited(_closeTransport(reason: 'controller_disposed'));
    accountUsage.dispose();
    unawaited(_setKeepAlive(false));
    super.dispose();
  }
}

bool _isUncertainSubmissionFailure(Object exception) =>
    exception is RpcTimeoutException || exception is RpcDisconnectedException;

String _friendlyError(Object exception) {
  if (exception is RpcRemoteException) return exception.message;
  final text = exception.toString();
  return text.replaceFirst(
      RegExp(r'^(Exception|StateError|ArgumentError):\s*'), '');
}

String describeConnectionFailure(
  ConnectionStage stage,
  Object exception,
  HostProfile profile,
) {
  final detail = _friendlyError(exception);
  final target = profile.proxyJump;
  final endpoint = target == null
      ? '${profile.hostName}:${profile.port}'
      : '${target.hostName}:${target.port}';
  return switch (stage) {
    ConnectionStage.profile => 'Could not read the SSH profile: $detail',
    ConnectionStage.ssh => 'SSH connection to $endpoint failed: $detail',
    ConnectionStage.remoteAppServer =>
      'SSH connected successfully, but the remote Codex app-server failed: '
          '$detail',
    ConnectionStage.unixTunnel =>
      'SSH connected successfully, but the remote Codex socket could not be '
          'forwarded: $detail',
    ConnectionStage.rpcTunnel =>
      'SSH connected successfully, but the Codex tunnel refused the local RPC '
          'connection: $detail',
    ConnectionStage.initialize =>
      'The Codex tunnel connected, but RPC initialization failed: $detail',
    ConnectionStage.refresh =>
      'Codex connected, but its task list could not be loaded: $detail',
  };
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
