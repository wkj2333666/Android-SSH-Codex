import 'dart:async';
import 'dart:convert';

import 'rpc_transport.dart';

final class RpcNotification {
  const RpcNotification(this.method, this.params);

  final String method;
  final Map<String, dynamic> params;
}

final class RpcServerRequest {
  const RpcServerRequest(this.id, this.method, this.params);

  final Object id;
  final String method;
  final Map<String, dynamic> params;
}

final class RpcRemoteException implements Exception {
  const RpcRemoteException(this.code, this.message, [this.data]);

  final int code;
  final String message;
  final Object? data;

  @override
  String toString() => 'RPC error $code: $message';
}

final class RpcDisconnectedException implements Exception {
  const RpcDisconnectedException([this.message = 'RPC transport disconnected']);

  final String message;

  @override
  String toString() => message;
}

final class RpcTimeoutException implements Exception {
  const RpcTimeoutException(this.method, this.requestId, this.timeout);

  final String method;
  final int requestId;
  final Duration timeout;

  @override
  String toString() => 'RPC request $method ($requestId) timed out after '
      '${timeout.inSeconds} seconds';
}

final class _PendingRpcRequest {
  _PendingRpcRequest(this.completer, this.timer);

  final Completer<dynamic> completer;
  final Timer timer;

  void cancel() => timer.cancel();
}

final class JsonRpcClient {
  JsonRpcClient(
    this._transport, {
    this.requestTimeout = const Duration(seconds: 30),
  });

  final RpcTransport _transport;
  final Duration requestTimeout;
  final Map<int, _PendingRpcRequest> _pending = {};
  final StreamController<RpcNotification> _notifications =
      StreamController.broadcast();
  final StreamController<RpcServerRequest> _serverRequests =
      StreamController.broadcast();
  StreamSubscription<String>? _subscription;
  final Completer<void> _done = Completer<void>();
  Future<void>? _cleanupFuture;
  var _nextId = 1;
  var _closed = false;

  Stream<RpcNotification> get notifications => _notifications.stream;
  Stream<RpcServerRequest> get serverRequests => _serverRequests.stream;
  Future<void> get done => _done.future;

  void start() {
    if (_subscription != null || _closed) return;
    _subscription = _transport.messages.listen(
      _handleMessage,
      onError: (Object error, StackTrace stackTrace) => _disconnect(error),
      onDone: _disconnect,
    );
  }

  Future<dynamic> request(
    String method, [
    Map<String, dynamic>? params,
  ]) {
    if (_closed) return Future.error(const RpcDisconnectedException());
    final id = _nextId++;
    final completer = Completer<dynamic>();
    final timer = Timer(
      requestTimeout,
      () => _handleRequestTimeout(id, method),
    );
    final pending = _PendingRpcRequest(completer, timer);
    _pending[id] = pending;
    try {
      _send({'method': method, 'id': id, if (params != null) 'params': params});
    } catch (error, stackTrace) {
      _pending.remove(id);
      pending.cancel();
      completer.completeError(error, stackTrace);
    }
    return completer.future;
  }

  void notify(String method, [Map<String, dynamic>? params]) {
    _send({'method': method, if (params != null) 'params': params});
  }

  void respond(Object id, Map<String, dynamic> result) {
    _send({'id': id, 'result': result});
  }

  void respondError(Object id, int code, String message) {
    _send({
      'id': id,
      'error': {'code': code, 'message': message},
    });
  }

  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      _failPending(const RpcDisconnectedException('RPC client closed'));
      if (!_done.isCompleted) _done.complete();
    }
    await _cleanup();
  }

  void _send(Map<String, dynamic> message) {
    if (_closed) throw const RpcDisconnectedException();
    _transport.send(jsonEncode(message));
  }

  void _handleMessage(String encoded) {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, dynamic>) return;
    final id = decoded['id'];
    final method = decoded['method'];
    final params = _asMap(decoded['params']);

    if (method is String && id != null) {
      _serverRequests.add(RpcServerRequest(id, method, params));
      return;
    }
    if (method is String) {
      _notifications.add(RpcNotification(method, params));
      return;
    }
    if (id is! int) return;
    final pending = _pending.remove(id);
    if (pending == null) return;
    pending.cancel();
    final completer = pending.completer;
    final error = decoded['error'];
    if (error is Map) {
      completer.completeError(RpcRemoteException(
        error['code'] as int? ?? -32000,
        error['message'] as String? ?? 'Unknown remote error',
        error['data'],
      ));
    } else {
      completer.complete(decoded['result']);
    }
  }

  void _handleRequestTimeout(int id, String method) {
    final pending = _pending.remove(id);
    if (pending == null) return;
    pending.cancel();
    final error = RpcTimeoutException(method, id, requestTimeout);
    pending.completer.completeError(error);
  }

  void _disconnect([Object? error]) {
    if (_closed) return;
    _closed = true;
    _failPending(RpcDisconnectedException(
      error == null
          ? 'RPC transport disconnected'
          : 'RPC transport failed: $error',
    ));
    if (!_done.isCompleted) _done.complete();
    unawaited(_cleanup());
  }

  Future<void> _cleanup() => _cleanupFuture ??= _performCleanup();

  Future<void> _performCleanup() async {
    await _subscription?.cancel();
    _subscription = null;
    await _transport.close();
    await _notifications.close();
    await _serverRequests.close();
  }

  void _failPending(Object error) {
    for (final pending in _pending.values) {
      pending.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error);
      }
    }
    _pending.clear();
  }
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  return const {};
}
