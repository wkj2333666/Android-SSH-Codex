import 'dart:async';

/// SSH-level reply watchdog. Never overlaps pings or treats a busy RPC server
/// as a broken network. The grace window also lets buffered replies run after
/// Android suspends and resumes the Dart event loop.
class SshHealthMonitor {
  SshHealthMonitor(
      {required this.ping,
      required this.onFailure,
      this.interval = const Duration(seconds: 15),
      this.timeout = const Duration(seconds: 8),
      this.grace = const Duration(seconds: 4)});
  final Future<void> Function() ping;
  final void Function(Object) onFailure;
  final Duration interval;
  final Duration timeout;
  final Duration grace;
  Timer? _timer;
  Future<bool>? _pending;
  bool _disposed = false;

  void start() {
    if (_disposed) return;
    _timer ??= Timer.periodic(interval, (_) {
      unawaited(check());
    });
  }

  Future<bool> check() {
    if (_disposed) return Future.value(false);
    return _pending ??= _check().whenComplete(() {
      _pending = null;
    });
  }

  Future<bool> _check() async {
    try {
      final reply = Future<void>.sync(ping);
      try {
        await reply.timeout(timeout);
      } on TimeoutException {
        // Await the SAME request: issuing new global requests after timeout
        // would grow dartssh2's reply queue on a blackholed connection.
        await reply.timeout(grace);
      }
      return !_disposed;
    } catch (error) {
      if (!_disposed) {
        dispose();
        onFailure(error);
      }
      return false;
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
