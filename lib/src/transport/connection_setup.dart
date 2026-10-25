import 'dart:async';

import '../diagnostics.dart';

/// Owns cancellation and deadlines only until a connection is ready.
/// Deadlines are also checked on resume because background timers may be delayed.
final class ConnectionSetup {
  ConnectionSetup(this.attempt, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final int attempt;
  final DateTime Function() _now;
  final _failure = Completer<Object>();
  final List<void Function()> _closers = [];
  Timer? _timer;
  DateTime? _deadline;
  String? _stage;
  bool _disposed = false;

  void cancel(Object error) {
    if (_disposed || _failure.isCompleted) return;
    _failure.complete(error);
    _timer?.cancel();
    for (final close in _closers.toList()) {
      try {
        close();
      } catch (closeError) {
        Diagnostics.record('connection.abortCleanupFailed', {
          'attempt': attempt,
          ...Diagnostics.errorFields(closeError),
        });
      }
    }
    _closers.clear();
  }

  void checkDeadline() {
    final deadline = _deadline;
    if (deadline != null && !_now().isBefore(deadline)) {
      cancel(TimeoutException('Connection setup timed out during $_stage'));
    }
  }

  void watchClosed(Future<void> done, void Function() close) {
    unawaited(done.then((_) {
      cancel(StateError('Transport closed during connection setup ($_stage)'));
    }, onError: (Object error) {
      cancel(error);
    }));
    if (_disposed || _failure.isCompleted) {
      close();
      return;
    }
    _closers.add(close);
  }

  Future<T> run<T>(
    String stage,
    Future<T> Function() operation, {
    Duration timeout = const Duration(seconds: 30),
    Future<void> Function(T)? closeLateResult,
  }) async {
    if (_failure.isCompleted) throw await _failure.future;
    if (_disposed) throw StateError('Connection setup already finished');
    _stage = stage;
    final started = _now();
    _deadline = started.add(timeout);
    _timer = Timer(timeout, () {
      cancel(TimeoutException('Connection setup timed out during $stage'));
    });
    Diagnostics.record('connection.stageStarted', {
      'attempt': attempt,
      'stage': stage,
      'timeoutMs': timeout.inMilliseconds,
    });
    try {
      final pending = operation().then((value) {
        if (_failure.isCompleted || _disposed) {
          if (closeLateResult != null) {
            unawaited(closeLateResult(value).catchError((Object error) {
              Diagnostics.record('connection.lateCleanupFailed', {
                'attempt': attempt,
                'stage': stage,
                ...Diagnostics.errorFields(error),
              });
            }));
          }
          throw StateError('Discarded late connection setup result');
        }
        return value;
      });
      return await Future.any([
        pending,
        _failure.future.then<T>((error) => throw error),
      ]);
    } catch (error) {
      cancel(error);
      rethrow;
    } finally {
      _timer?.cancel();
      _deadline = null;
      Diagnostics.record('connection.stageFinished', {
        'attempt': attempt,
        'stage': stage,
        'durationMs': _now().difference(started).inMilliseconds,
        'failed': _failure.isCompleted,
      });
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _deadline = null;
    _closers.clear();
  }
}

Future<void> boundedConnectionCleanup(
  String resource,
  Future<void> Function() close, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  try {
    await close().timeout(timeout);
  } catch (error) {
    Diagnostics.record('connection.cleanupFailed', {
      'resource': resource,
      ...Diagnostics.errorFields(error),
    });
  }
}
