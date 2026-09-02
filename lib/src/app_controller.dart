import 'dart:async';

import 'package:flutter/foundation.dart';

import 'profiles/host_profile.dart';
import 'profiles/profile_store.dart';
import 'projects/remote_project.dart';
import 'protocol/codex_remote_api.dart';
import 'protocol/json_rpc_client.dart';
import 'protocol/websocket_rpc_transport.dart';
import 'tasks/task_catalog.dart';
import 'tasks/task_event_batcher.dart';
import 'tasks/task_message_queue.dart';
import 'tasks/task_operation_lock.dart';
import 'tasks/task_reducer.dart';
import 'tasks/task_refresh_lock.dart';
import 'transport/codex_daemon.dart';
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
  });

  final String id;
  final String text;
  final RemoteSkill? skill;
  final String? model;
  final String? effort;

  String get timelineItemId => 'local-user:$id';
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

bool requiresThreadResumeForSend({
  required bool owned,
  required bool subscribed,
}) =>
    !owned || !subscribed;

bool requiresThreadResumeForSteer({required bool subscribed}) => !subscribed;

final class AppController extends ChangeNotifier {
  AppController({required ProfileStore store})
      : _store = store,
        _connector = SshConnector(store);

  factory AppController.memory() => AppController(store: MemoryProfileStore());

  final ProfileStore _store;
  final SshConnector _connector;
  final TaskReducer _taskReducer = TaskReducer();
  late final TaskEventBatcher _agentDeltaBatcher = TaskEventBatcher(
    onFlush: _applyAgentDeltaBatch,
  );
  final TaskCatalog _taskCatalog = TaskCatalog();
  final TaskHistoryLoadState _historyLoadState = TaskHistoryLoadState();
  final TaskMessageQueue<QueuedTaskMessage> _messageQueue = TaskMessageQueue();
  final TaskOperationLock _messageOperations = TaskOperationLock();
  final TaskRefreshLock<CodexRemoteApi> _refreshOperations = TaskRefreshLock();

  List<HostProfile> _profiles = const [];
  List<RemoteProject> _projects = const [];
  List<RemoteModel> _models = const [];
  AppSection _section = AppSection.hosts;
  RemoteConnectionPhase _connectionPhase = RemoteConnectionPhase.disconnected;
  String? _selectedHostId;
  String? _selectedProjectId;
  String? _selectedTaskId;
  final Map<String, String> _activeTurnIds = {};
  final Map<String, DateTime> _projectActivityByCwd = {};
  String? _error;
  HostKeyChallenge? _hostKeyChallenge;
  Completer<bool>? _hostKeyCompleter;
  List<PendingApproval> _approvals = const [];
  Set<String> _ownedThreadIds = {};
  Set<String> _loadedThreadIds = {};
  Set<String> _subscribedThreadIds = {};
  SshConnection? _ssh;
  SshUnixTunnel? _tunnel;
  JsonRpcClient? _rpc;
  CodexRemoteApi? _api;
  CodexRemoteApi? _projectDiscoveryApi;
  StreamSubscription<RpcNotification>? _notificationSubscription;
  StreamSubscription<RpcServerRequest>? _requestSubscription;
  Timer? _refreshTimer;
  Timer? _reconnectTimer;
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
  String? get selectedHostId => _selectedHostId;
  String? get selectedProjectId => _selectedProjectId;
  String? get selectedTaskId => _selectedTaskId;
  String? get error => _error;
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
    notifyListeners();
    if (autoConnectProfile != null) {
      unawaited(connectHost(autoConnectProfile));
    }
  }

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
    await _store.deleteProfile(id);
    _profiles = await _store.readProfiles();
    notifyListeners();
  }

  Future<HostSecret> readSecret(String id) => _store.readSecret(id);

  Future<void> connectHost(HostProfile profile) async {
    final attempt = ++_connectionAttempt;
    _cancelHostKeyPrompt();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    _messageQueue.clear();
    _messageOperations.clear();
    await _closeTransport();
    if (attempt != _connectionAttempt) return;
    _agentDeltaBatcher.clear();
    _epoch = _taskReducer.beginConnection();
    await _openConnection(profile, attempt: attempt, reconnecting: false);
  }

  Future<void> _openConnection(
    HostProfile profile, {
    required int attempt,
    required bool reconnecting,
  }) async {
    _selectedHostId = profile.id;
    if (!reconnecting) _selectedTaskId = null;
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
      final secret = await _store.readSecret(profile.id);
      final ownedThreadIds = await _store.readOwnedThreads(profile.id);
      final projects =
          reconnecting ? _projects : await _store.readProjects(profile.id);
      if (attempt != _connectionAttempt) return;
      if (!reconnecting) {
        _projectActivityByCwd.clear();
        _projects = projects;
        _selectedProjectId = projects.firstOrNull?.id;
        _taskCatalog.clear();
        _historyLoadState.clear();
      }
      stage = ConnectionStage.ssh;
      ssh = await _connector.connect(
        profile,
        secret,
        prompt: _promptForHostKey,
      );
      stage = ConnectionStage.remoteAppServer;
      final client = ssh.client;
      final socketPath = await resolveCodexSocketForProfile(
        (command, {environment}) async {
          final result = await client.runWithResult(
            command,
            environment: environment,
          );
          return SshCommandResult(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            exitSignal: result.exitSignal?.signalName,
          );
        },
        profile,
      );
      if (attempt != _connectionAttempt) return;
      stage = ConnectionStage.unixTunnel;
      tunnel = await SshUnixTunnel.start(
        ssh.client,
        socketPath,
        environment: profile.environment,
      );
      stage = ConnectionStage.rpcTunnel;
      final tunnelFailure = tunnel.firstFailure.then<WebSocketRpcTransport>(
        (_) => throw StateError(
          'Remote Codex tunnel stopped without reporting a failure.',
        ),
      );
      final transport = await Future.any<WebSocketRpcTransport>([
        WebSocketRpcTransport.connect(
          Uri.parse('ws://127.0.0.1:${tunnel.localPort}/'),
        ),
        tunnelFailure,
      ]);
      rpc = JsonRpcClient(transport)..start();
      final api = CodexRemoteApi(rpc);
      notifications = api.notifications.listen(
        (notification) => _handleNotification(attempt, notification),
      );
      requests = api.serverRequests.listen(
        (request) => _handleServerRequest(attempt, request),
      );
      stage = ConnectionStage.initialize;
      await api.initialize();
      if (attempt != _connectionAttempt) return;
      try {
        _models = await api.readModelCatalog();
      } catch (exception) {
        _models = const [];
        debugPrint('Could not read remote model catalog: $exception');
      }
      if (attempt != _connectionAttempt) return;

      _ssh = ssh;
      _tunnel = tunnel;
      _rpc = rpc;
      _api = api;
      _notificationSubscription = notifications;
      _requestSubscription = requests;
      _ownedThreadIds = ownedThreadIds;
      _loadedThreadIds = {};
      _subscribedThreadIds = {};
      published = true;
      unawaited(rpc.done.then((_) => _handleTransportLoss(attempt, profile)));
      stage = ConnectionStage.refresh;
      await refreshTasks(throwOnError: true, resetPages: true);
      if (attempt != _connectionAttempt) return;
      _connectionPhase = RemoteConnectionPhase.connected;
      _reconnectAttempt = 0;
      if (reconnecting) {
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
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(refreshTasks()),
      );
    } catch (exception, stackTrace) {
      if (attempt != _connectionAttempt) return;
      debugPrint(
        'Connection failed during ${stage.name} for '
        '${profile.hostName}:${profile.port}: $exception',
      );
      debugPrintStack(stackTrace: stackTrace);
      _error = describeConnectionFailure(stage, exception, profile);
      if (published) await _closeTransport();
      if (reconnecting) {
        _connectionPhase = RemoteConnectionPhase.reconnecting;
        _scheduleReconnect(profile, attempt);
      } else {
        _connectionPhase = RemoteConnectionPhase.disconnected;
      }
    } finally {
      if (!published) {
        await notifications?.cancel();
        await requests?.cancel();
        await rpc?.close();
        await tunnel?.close();
        await ssh?.close();
      }
    }
    notifyListeners();
  }

  Future<void> _handleTransportLoss(int attempt, HostProfile profile) async {
    if (attempt != _connectionAttempt ||
        _connectionPhase != RemoteConnectionPhase.connected) {
      return;
    }
    _connectionPhase = RemoteConnectionPhase.reconnecting;
    _error = 'Remote connection lost. Reconnecting...';
    notifyListeners();
    await _closeTransport();
    if (attempt == _connectionAttempt) _scheduleReconnect(profile, attempt);
  }

  void _scheduleReconnect(HostProfile profile, int attempt) {
    if (attempt != _connectionAttempt || _reconnectTimer != null) return;
    const delays = [1, 2, 4, 8, 15];
    final delayIndex = _reconnectAttempt < delays.length
        ? _reconnectAttempt
        : delays.length - 1;
    final seconds = delays[delayIndex];
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
        final initialProject = selectedProject;
        final token = _taskReducer.beginRefresh(epoch);
        final loadedFuture = api.readLoadedThreadIds();
        final unassignedFuture = api.readTaskPage();
        final initialProjectFuture = initialProject == null
            ? Future<RemoteTaskPage?>.value()
            : api.readTaskPage(cwd: initialProject.cwd);
        final loadedThreadIds = await loadedFuture;
        final unassignedPage = await unassignedFuture;
        if (api != _api || epoch != _epoch) return;
        _discoverProjects(unassignedPage.tasks);
        final project = selectedProject;
        final selectedProjectId = project?.id;
        final projectPage = project == null
            ? null
            : initialProject?.id == project.id
                ? await initialProjectFuture
                : await api.readTaskPage(cwd: project.cwd);
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
        final loadedByUs = loadedThreadIds.intersection(_ownedThreadIds);
        _loadedThreadIds = loadedThreadIds;
        _taskReducer.applyRefresh(
          token,
          snapshots.values.toList(growable: false),
          loadedByUs,
          retainExisting: !shouldResetPages,
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
    _taskReducer.replaceItems(_epoch, taskId, const []);
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
    final token = _historyLoadState.beginInitial(taskId);
    notifyListeners();
    try {
      final page = await api.readThreadTurnsPage(taskId);
      if (api != _api || epoch != _epoch) return;
      if (!_historyLoadState.complete(token, nextCursor: page.nextCursor)) {
        return;
      }
      _taskReducer.prependItems(epoch, taskId, page.items);
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
    _selectedProjectId = projectId;
    _selectedTaskId = null;
    _historyLoadState.clear();
    _taskCatalog.clearProjectPage();
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
      final page = await api.readTaskPage(cwd: project.cwd);
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
        _loadedThreadIds.intersection(_ownedThreadIds),
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
    final matchingCwd = _projects
        .where((project) => normalizeRemoteCwd(project.cwd) == normalizedCwd)
        .firstOrNull;
    final id = projectId ??
        matchingCwd?.id ??
        '$hostId-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    await _store.writeProject(
      RemoteProject(
        id: id,
        hostId: hostId,
        name: normalizedName,
        cwd: normalizedCwd,
      ),
    );
    _projects = mergeRemoteProjects(
      hostId: hostId,
      existing: await _store.readProjects(hostId),
      discoveredCwds: _taskReducer.state.tasks.values.map((task) => task.cwd),
      activityByCwd: _projectActivityByCwd,
    );
    _selectedProjectId = id;
    _selectedTaskId = null;
    _historyLoadState.clear();
    _taskCatalog.clearProjectPage();
    notifyListeners();
    await refreshTasks(resetPages: true);
  }

  Future<void> deleteProject(String projectId) async {
    final hostId = _selectedHostId;
    if (hostId == null) return;
    await _store.deleteProject(hostId, projectId);
    _projects = mergeRemoteProjects(
      hostId: hostId,
      existing: await _store.readProjects(hostId),
      discoveredCwds: _taskReducer.state.tasks.values.map((task) => task.cwd),
      activityByCwd: _projectActivityByCwd,
    );
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
      final page = await api.readTaskPage(
        cwd: project.cwd,
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
        _loadedThreadIds.intersection(_ownedThreadIds),
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
        _loadedThreadIds.intersection(_ownedThreadIds),
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
        _loadedThreadIds.intersection(_ownedThreadIds),
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
    String? model,
    String? effort,
  }) async {
    final api = _requireApi();
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    final profileId = _selectedHostId!;
    final threadId = await api.startThread(cwd: cwd);
    if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
    if (!await _claimThread(
      threadId,
      api: api,
      attempt: attempt,
      epoch: epoch,
      profileId: profileId,
    )) {
      return;
    }
    _loadedThreadIds = {..._loadedThreadIds, threadId};
    _subscribedThreadIds = {..._subscribedThreadIds, threadId};
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
    );
    if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
    await refreshTasks();
  }

  Future<TaskMessageDisposition> sendPrompt(
    String prompt, {
    RemoteSkill? skill,
    String? model,
    String? effort,
  }) async {
    final api = _requireApi();
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    final profileId = _selectedHostId!;
    final task = selectedTask;
    if (task == null) throw StateError('Select or create a task first.');
    final normalized = prompt.trim();
    if (normalized.isEmpty) throw ArgumentError('Message is required.');
    final pending = QueuedTaskMessage(
      id: 'queued-${_nextQueuedMessageId++}',
      text: skill == null ? normalized : '\$${skill.name} $normalized',
      skill: skill,
      model: model,
      effort: effort,
    );
    if (_messageQueue.hasPending(task.id)) {
      _enqueuePrompt(task.id, pending);
      return TaskMessageDisposition.queued;
    }

    var activeTurnId = _activeTurnIds[task.id];
    if (activeTurnId == null &&
        (task.status == TaskStatus.running ||
            task.status == TaskStatus.queued)) {
      activeTurnId = await api.readActiveTurnId(task.id);
      _ensureCurrentSession(api, attempt, epoch, profileId);
      if (activeTurnId != null) _activeTurnIds[task.id] = activeTurnId;
    }
    switch (chooseTaskMessageRoute(
      task.status,
      activeTurnId: activeTurnId,
    )) {
      case TaskMessageRoute.steer:
        return _steerPrompt(
          task,
          pending,
          activeTurnId!,
          api: api,
          attempt: attempt,
          epoch: epoch,
          profileId: profileId,
        );
      case TaskMessageRoute.queue:
        _enqueuePrompt(task.id, pending);
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
        steerRequested = true;
        await api.steerTurn(task.id, turnId, pending.text);
        _ensureCurrentSession(api, attempt, epoch, profileId);
      } on RpcRemoteException {
        steerRequested = false;
        final refreshedTurnId = await api.readActiveTurnId(task.id);
        _ensureCurrentSession(api, attempt, epoch, profileId);
        if (refreshedTurnId == null) {
          _activeTurnIds.remove(task.id);
          _setLocalUserMessageStatus(
            task.id,
            pending,
            'queued',
            epoch: epoch,
          );
          _enqueuePrompt(task.id, pending);
          return TaskMessageDisposition.queued;
        }
        if (refreshedTurnId == turnId) rethrow;
        _activeTurnIds[task.id] = refreshedTurnId;
        steerRequested = true;
        await api.steerTurn(task.id, refreshedTurnId, pending.text);
        _ensureCurrentSession(api, attempt, epoch, profileId);
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
        _recordSubmittedPrompt(
          task.id,
          pending,
          api: api,
          attempt: attempt,
          epoch: epoch,
          profileId: profileId,
        );
        return TaskMessageDisposition.steered;
      }
      _setLocalUserMessageStatus(task.id, pending, 'failed', epoch: epoch);
      rethrow;
    }
  }

  void _enqueuePrompt(String threadId, QueuedTaskMessage pending) {
    _messageQueue.enqueue(threadId, pending);
    notifyListeners();
    unawaited(_flushQueuedPrompt(threadId));
  }

  Future<void> _startPendingPrompt(
    TaskRecord task,
    QueuedTaskMessage pending,
  ) async {
    final api = _requireApi();
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    final profileId = _selectedHostId!;
    _setLocalUserMessageStatus(task.id, pending, 'sending', epoch: epoch);
    var turnRequested = false;
    try {
      if (requiresThreadResumeForSend(
        owned: _ownedThreadIds.contains(task.id),
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
      if (!_ownedThreadIds.contains(task.id)) {
        if (!await _claimThread(
          task.id,
          api: api,
          attempt: attempt,
          epoch: epoch,
          profileId: profileId,
        )) {
          throw StateError('Connection changed before the task was claimed.');
        }
      }
      turnRequested = true;
      await api.startTurn(
        task.id,
        pending.text,
        skill: pending.skill,
        model: pending.model,
        effort: pending.effort,
      );
      _ensureCurrentSession(api, attempt, epoch, profileId);
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
        _recordSubmittedPrompt(
          task.id,
          pending,
          api: api,
          attempt: attempt,
          epoch: epoch,
          profileId: profileId,
        );
        return;
      }
      _setLocalUserMessageStatus(task.id, pending, 'failed', epoch: epoch);
      rethrow;
    }
  }

  void _setLocalUserMessageStatus(
    String threadId,
    QueuedTaskMessage pending,
    String status, {
    required int epoch,
  }) {
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
    if (_ownedThreadIds.contains(threadId)) {
      try {
        await _ensureThreadSubscribed(
          threadId,
          api: api,
          attempt: attempt,
          epoch: epoch,
          profileId: profileId,
        );
      } catch (exception) {
        debugPrint('Could not restore selected task subscription: $exception');
      }
    }
    await _catchUpTaskContext(
      threadId,
      api: api,
      attempt: attempt,
      epoch: epoch,
      profileId: profileId,
    );
  }

  Future<void> _catchUpTaskContext(
    String threadId, {
    required CodexRemoteApi api,
    required int attempt,
    required int epoch,
    required String profileId,
  }) async {
    try {
      final page = await api.readThreadTurnsPage(threadId);
      if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
      _taskReducer.mergeLatestItems(epoch, threadId, page.items);
      notifyListeners();
    } catch (exception) {
      debugPrint('Could not catch up selected task context: $exception');
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
      if (pending == null || task == null || !isConnected) {
        return;
      }
      String? activeTurnId;
      var activeTurnChecked = false;
      if (task.status == TaskStatus.running ||
          task.status == TaskStatus.queued) {
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
      await _startPendingPrompt(task, pending);
      if (identical(_messageQueue.peek(threadId), pending)) {
        _messageQueue.take(threadId);
        notifyListeners();
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
      unawaited(_flushQueuedPrompt(threadId));
    }
  }

  Future<void> removeQueuedMessage(String taskId, String messageId) async {
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
        notifyListeners();
      }
    } finally {
      _messageOperations.release(taskId, operation);
    }
  }

  Future<void> steerQueuedMessage(String taskId, String messageId) async {
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
          steerRequested = true;
          await api.steerTurn(taskId, turnId, pending.text);
          _ensureCurrentSession(api, attempt, epoch, profileId);
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
          await api.steerTurn(taskId, refreshedTurnId, pending.text);
          _ensureCurrentSession(api, attempt, epoch, profileId);
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
          _recordSubmittedPrompt(
            taskId,
            pending,
            api: api,
            attempt: attempt,
            epoch: epoch,
            profileId: profileId,
          );
          if (_messageQueue.remove(taskId, pending)) notifyListeners();
          return;
        }
        _setLocalUserMessageStatus(taskId, pending, 'queued', epoch: epoch);
        rethrow;
      }
    } finally {
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

  Future<RemoteThreadGoal?> readSelectedGoal() {
    final task = selectedTask;
    if (task == null) throw StateError('Select a task first.');
    return _requireApi().readThreadGoal(task.id);
  }

  Future<RemoteThreadGoal> setSelectedGoal({
    required String objective,
    int? tokenBudget,
  }) {
    final task = selectedTask;
    if (task == null) throw StateError('Select a task first.');
    final normalizedObjective = objective.trim();
    if (normalizedObjective.isEmpty) {
      throw ArgumentError('Goal objective is required.');
    }
    if (tokenBudget != null && tokenBudget <= 0) {
      throw ArgumentError('Token budget must be positive.');
    }
    return _requireApi().setThreadGoal(
      task.id,
      objective: normalizedObjective,
      tokenBudget: tokenBudget,
    );
  }

  Future<void> clearSelectedGoal() {
    final task = selectedTask;
    if (task == null) throw StateError('Select a task first.');
    return _requireApi().clearThreadGoal(task.id);
  }

  Future<void> compactSelectedTask() {
    final task = selectedTask;
    if (task == null) throw StateError('Select a task first.');
    if (!task.canWrite) {
      throw StateError('This running task is owned by another Codex client.');
    }
    return _requireApi().compactThread(task.id);
  }

  Future<void> interruptSelectedTask() async {
    final task = selectedTask;
    final turnId = task == null ? null : _activeTurnIds[task.id];
    if (task == null || !task.canWrite || turnId == null) return;
    await _requireApi().interruptTurn(task.id, turnId);
  }

  Future<void> guideExternalTask(String guidance) async {
    final task = selectedTask;
    if (task == null || task.ownership != TaskOwnership.external) {
      throw StateError('Select a task running in another client first.');
    }
    final normalized = guidance.trim();
    if (normalized.isEmpty) throw ArgumentError('Guidance is required.');
    final api = _requireApi();
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    final profileId = _selectedHostId!;
    await _ensureThreadSubscribed(
      task.id,
      api: api,
      attempt: attempt,
      epoch: epoch,
      profileId: profileId,
    );
    final turnId = await api.readActiveTurnId(task.id);
    _ensureCurrentSession(api, attempt, epoch, profileId);
    if (turnId == null) {
      throw StateError('The other client no longer has an active turn.');
    }
    var steerRequested = false;
    try {
      steerRequested = true;
      await api.steerTurn(task.id, turnId, normalized);
      _ensureCurrentSession(api, attempt, epoch, profileId);
    } catch (exception) {
      if (!(steerRequested && _isUncertainSubmissionFailure(exception))) {
        rethrow;
      }
    }
    unawaited(_catchUpTaskContext(
      task.id,
      api: api,
      attempt: attempt,
      epoch: epoch,
      profileId: profileId,
    ));
  }

  Future<void> takeOverExternalTask() async {
    final task = selectedTask;
    final profileId = _selectedHostId;
    if (task == null ||
        profileId == null ||
        task.ownership != TaskOwnership.external) {
      throw StateError('Select a task running in another client first.');
    }
    final api = _requireApi();
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    final turnId = await api.readActiveTurnId(task.id);
    if (turnId != null) await api.interruptTurn(task.id, turnId);
    if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
    await _ensureThreadSubscribed(
      task.id,
      api: api,
      attempt: attempt,
      epoch: epoch,
      profileId: profileId,
    );
    if (!await _claimThread(
      task.id,
      api: api,
      attempt: attempt,
      epoch: epoch,
      profileId: profileId,
    )) {
      return;
    }
    _activeTurnIds.remove(task.id);
    _taskReducer.applyEvent(
      epoch,
      TaskEvent.statusChanged(task.id, TaskStatus.interrupted),
    );
    notifyListeners();
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

  Future<bool> _claimThread(
    String threadId, {
    required CodexRemoteApi api,
    required int attempt,
    required int epoch,
    required String profileId,
  }) async {
    if (!_isCurrentSession(api, attempt, epoch, profileId)) return false;
    final owned = {..._ownedThreadIds, threadId};
    await _store.writeOwnedThreads(profileId, owned);
    if (!_isCurrentSession(api, attempt, epoch, profileId)) return false;
    _ownedThreadIds = owned;
    return true;
  }

  Future<void> _ensureThreadSubscribed(
    String threadId, {
    required CodexRemoteApi api,
    required int attempt,
    required int epoch,
    required String profileId,
  }) async {
    if (_subscribedThreadIds.contains(threadId)) return;
    await api.resumeThread(threadId);
    _ensureCurrentSession(api, attempt, epoch, profileId);
    _loadedThreadIds = {..._loadedThreadIds, threadId};
    _subscribedThreadIds = {..._subscribedThreadIds, threadId};
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

  Future<void> disconnect() async {
    _connectionAttempt++;
    _cancelHostKeyPrompt();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _connectionPhase = RemoteConnectionPhase.disconnected;
    _selectedTaskId = null;
    _selectedProjectId = null;
    _projects = const [];
    _projectActivityByCwd.clear();
    _models = const [];
    _loadingProjectPage = false;
    _loadingRecentPage = false;
    _loadingUnassignedPage = false;
    _projectPageGeneration++;
    _taskCatalog.clear();
    _historyLoadState.clear();
    _activeTurnIds.clear();
    _messageQueue.clear();
    _messageOperations.clear();
    _loadedThreadIds = {};
    _subscribedThreadIds = {};
    _ownedThreadIds = {};
    _agentDeltaBatcher.clear();
    _epoch = _taskReducer.beginConnection();
    _approvals = const [];
    await _closeTransport();
    try {
      await _writeAutoConnectIntent(null);
    } catch (exception) {
      _error = 'Disconnected, but could not clear auto-connect: $exception';
    }
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

  List<TaskRecord> _tasksForIds(List<String> ids) => ids
      .map((id) => _taskReducer.state.tasks[id])
      .whereType<TaskRecord>()
      .toList(growable: false);

  Future<void> _closeTransport() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _agentDeltaBatcher.clear();
    _approvals = const [];
    _models = const [];
    _projectDiscoveryApi = null;
    _subscribedThreadIds = {};
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
    await notificationSubscription?.cancel();
    await requestSubscription?.cancel();
    await rpc?.close();
    await tunnel?.close();
    await ssh?.close();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _connectionAttempt++;
    _cancelHostKeyPrompt();
    _reconnectTimer?.cancel();
    _refreshTimer?.cancel();
    _agentDeltaBatcher.dispose();
    unawaited(_closeTransport());
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
