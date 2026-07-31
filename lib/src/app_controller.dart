import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'profiles/host_profile.dart';
import 'profiles/profile_store.dart';
import 'protocol/codex_remote_api.dart';
import 'protocol/json_rpc_client.dart';
import 'protocol/websocket_rpc_transport.dart';
import 'tasks/task_reducer.dart';
import 'transport/codex_daemon.dart';
import 'transport/ssh_connector.dart';
import 'transport/ssh_unix_tunnel.dart';

enum AppSection { hosts, tasks }

enum RemoteConnectionPhase { disconnected, connecting, connected, reconnecting }

Future<List<int>> bootstrapCodexForProfile(
  SshCommandRunner run,
  HostProfile profile,
) =>
    CodexDaemon.bootstrap(run, environment: profile.environment);

final class AppController extends ChangeNotifier {
  AppController({required ProfileStore store})
      : _store = store,
        _connector = SshConnector(store);

  factory AppController.memory() => AppController(store: MemoryProfileStore());

  final ProfileStore _store;
  final SshConnector _connector;
  final TaskReducer _taskReducer = TaskReducer();

  List<HostProfile> _profiles = const [];
  AppSection _section = AppSection.hosts;
  RemoteConnectionPhase _connectionPhase = RemoteConnectionPhase.disconnected;
  String? _selectedHostId;
  String? _selectedTaskId;
  final Map<String, String> _activeTurnIds = {};
  String? _error;
  HostKeyChallenge? _hostKeyChallenge;
  Completer<bool>? _hostKeyCompleter;
  List<PendingApproval> _approvals = const [];
  Set<String> _ownedThreadIds = {};
  Set<String> _loadedThreadIds = {};
  SshConnection? _ssh;
  SshUnixTunnel? _tunnel;
  JsonRpcClient? _rpc;
  CodexRemoteApi? _api;
  StreamSubscription<RpcNotification>? _notificationSubscription;
  StreamSubscription<RpcServerRequest>? _requestSubscription;
  Timer? _refreshTimer;
  Timer? _reconnectTimer;
  var _epoch = 0;
  var _connectionAttempt = 0;
  var _reconnectAttempt = 0;
  var _refreshing = false;
  var _refreshQueued = false;

  List<HostProfile> get profiles => _profiles;
  AppSection get section => _section;
  RemoteConnectionPhase get connectionPhase => _connectionPhase;
  String? get selectedHostId => _selectedHostId;
  String? get selectedTaskId => _selectedTaskId;
  String? get error => _error;
  HostKeyChallenge? get hostKeyChallenge => _hostKeyChallenge;
  List<PendingApproval> get approvals => _approvals;
  TaskState get taskState => _taskReducer.state;

  HostProfile? get selectedHost =>
      _profiles.where((profile) => profile.id == _selectedHostId).firstOrNull;

  TaskRecord? get selectedTask => _selectedTaskId == null
      ? null
      : _taskReducer.state.tasks[_selectedTaskId];

  bool get isConnected => _connectionPhase == RemoteConnectionPhase.connected;

  Future<void> initialize() async {
    try {
      _profiles = await _store.readProfiles();
    } catch (exception) {
      _profiles = const [];
      _error = 'Could not read secure storage: $exception';
    }
    notifyListeners();
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
    await _closeTransport();
    if (attempt != _connectionAttempt) return;
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
    try {
      final secret = await _store.readSecret(profile.id);
      final ownedThreadIds = await _store.readOwnedThreads(profile.id);
      if (attempt != _connectionAttempt) return;
      ssh = await _connector.connect(
        profile,
        secret,
        prompt: _promptForHostKey,
      );
      final output = utf8.decode(
        await bootstrapCodexForProfile(ssh.client.run, profile),
        allowMalformed: true,
      );
      final socketPath = output
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .where((line) => line.endsWith('app-server.sock'))
          .lastOrNull;
      if (socketPath == null) {
        throw StateError('Remote Codex app-server did not report its socket.');
      }
      if (attempt != _connectionAttempt) return;
      tunnel = await SshUnixTunnel.start(ssh.client, socketPath);
      final transport = await WebSocketRpcTransport.connect(
        Uri.parse('ws://127.0.0.1:${tunnel.localPort}/'),
      );
      rpc = JsonRpcClient(transport)..start();
      final api = CodexRemoteApi(rpc);
      notifications = api.notifications.listen(
        (notification) => _handleNotification(attempt, notification),
      );
      requests = api.serverRequests.listen(
        (request) => _handleServerRequest(attempt, request),
      );
      await api.initialize();
      if (attempt != _connectionAttempt) return;

      _ssh = ssh;
      _tunnel = tunnel;
      _rpc = rpc;
      _api = api;
      _notificationSubscription = notifications;
      _requestSubscription = requests;
      _ownedThreadIds = ownedThreadIds;
      _loadedThreadIds = {};
      published = true;
      unawaited(rpc.done.then((_) => _handleTransportLoss(attempt, profile)));
      await refreshTasks(throwOnError: true);
      if (attempt != _connectionAttempt) return;
      _connectionPhase = RemoteConnectionPhase.connected;
      _reconnectAttempt = 0;
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => unawaited(refreshTasks()),
      );
    } catch (exception) {
      if (attempt != _connectionAttempt) return;
      _error = _friendlyError(exception);
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

  Future<void> refreshTasks({bool throwOnError = false}) async {
    final api = _api;
    final epoch = _epoch;
    final connecting = _connectionPhase == RemoteConnectionPhase.connecting ||
        _connectionPhase == RemoteConnectionPhase.reconnecting;
    if (api == null || (!isConnected && !connecting)) return;
    if (_refreshing) {
      _refreshQueued = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshQueued = false;
        final token = _taskReducer.beginRefresh(epoch);
        final batch = await api.readTaskBatch();
        if (api != _api || epoch != _epoch) return;
        final snapshots = {for (final task in batch.tasks) task.id: task};
        final loadedByUs = batch.loadedThreadIds.intersection(_ownedThreadIds);
        final detailIds = <String>{
          if (_selectedTaskId != null) _selectedTaskId!,
          for (final task in batch.tasks)
            if ((task.status == TaskStatus.running ||
                    task.status == TaskStatus.queued) &&
                !loadedByUs.contains(task.id))
              task.id,
        };
        final details = await Future.wait(detailIds.map((id) async {
          try {
            return await api.readThread(id);
          } catch (_) {
            return null;
          }
        }));
        if (api != _api || epoch != _epoch) return;
        for (final detail in details.whereType<TaskSnapshot>()) {
          snapshots[detail.id] = detail;
        }
        _loadedThreadIds = batch.loadedThreadIds;
        _taskReducer.applyRefresh(token, snapshots.values.toList(), loadedByUs);
        notifyListeners();
      } while (_refreshQueued && isConnected);
    } catch (exception) {
      if (throwOnError) rethrow;
      _error = _friendlyError(exception);
      notifyListeners();
    } finally {
      _refreshing = false;
    }
  }

  Future<void> selectTask(String taskId) async {
    _selectedTaskId = taskId;
    _section = AppSection.tasks;
    notifyListeners();
    await refreshTasks();
  }

  void clearSelectedTask() {
    _selectedTaskId = null;
    notifyListeners();
  }

  Future<void> startNewTask(
      {required String cwd, required String prompt}) async {
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
    _selectedTaskId = threadId;
    _taskReducer.applyEvent(
      _epoch,
      TaskEvent.statusChanged(threadId, TaskStatus.running),
    );
    notifyListeners();
    await api.startTurn(threadId, prompt);
    if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
    await refreshTasks();
  }

  Future<void> sendPrompt(String prompt) async {
    final api = _requireApi();
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    final profileId = _selectedHostId!;
    final task = selectedTask;
    if (task == null) throw StateError('Select or create a task first.');
    if (!task.canWrite) {
      throw StateError('This running task is owned by another Codex client.');
    }
    if (!_ownedThreadIds.contains(task.id) ||
        !_loadedThreadIds.contains(task.id)) {
      await api.resumeThread(task.id);
      if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
      if (!await _claimThread(
        task.id,
        api: api,
        attempt: attempt,
        epoch: epoch,
        profileId: profileId,
      )) {
        return;
      }
      _loadedThreadIds = {..._loadedThreadIds, task.id};
    }
    await api.startTurn(task.id, prompt);
    if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
    _taskReducer.applyEvent(
      _epoch,
      TaskEvent.statusChanged(task.id, TaskStatus.running),
    );
    notifyListeners();
  }

  Future<void> interruptSelectedTask() async {
    final task = selectedTask;
    final turnId = task == null ? null : _activeTurnIds[task.id];
    if (task == null || !task.canWrite || turnId == null) return;
    await _requireApi().interruptTurn(task.id, turnId);
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

  void _handleNotification(int attempt, RpcNotification notification) {
    if (attempt != _connectionAttempt) return;
    final event = CodexRemoteApi.parseNotification(
      notification.method,
      notification.params,
    );
    if (event != null) _taskReducer.applyEvent(_epoch, event);
    final threadId = notification.params['threadId'] as String? ??
        (notification.params['thread'] is Map
            ? (notification.params['thread'] as Map)['id'] as String?
            : null);
    if (notification.method == 'turn/started') {
      final turn = notification.params['turn'];
      final turnId = turn is Map ? turn['id'] as String? : null;
      if (threadId != null && turnId != null) {
        _activeTurnIds[threadId] = turnId;
      }
    } else if (notification.method == 'turn/completed' && threadId != null) {
      _activeTurnIds.remove(threadId);
      unawaited(refreshTasks());
    }
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
    _activeTurnIds.clear();
    _loadedThreadIds = {};
    _ownedThreadIds = {};
    _epoch = _taskReducer.beginConnection();
    _approvals = const [];
    await _closeTransport();
    notifyListeners();
  }

  Future<void> _closeTransport() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _approvals = const [];
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
    unawaited(_closeTransport());
    super.dispose();
  }
}

String _friendlyError(Object exception) {
  if (exception is RpcRemoteException) return exception.message;
  final text = exception.toString();
  return text.replaceFirst(
      RegExp(r'^(Exception|StateError|ArgumentError):\s*'), '');
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }

  T? get lastOrNull {
    T? result;
    var found = false;
    for (final item in this) {
      result = item;
      found = true;
    }
    return found ? result : null;
  }
}
