import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../diagnostics.dart';
import 'codex_daemon.dart';

abstract interface class SshProxyChannel {
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  StreamSink<Uint8List> get stdin;
  Future<void> get done;
  int? get exitCode;
  String? get exitSignal;
  void close();
}

typedef SshProxyOpener = Future<SshProxyChannel> Function();

final class CodexProxyException implements Exception {
  const CodexProxyException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class _SshSessionProxyChannel implements SshProxyChannel {
  const _SshSessionProxyChannel(this._session);

  final SSHSession _session;

  @override
  Stream<Uint8List> get stdout => _session.stdout;

  @override
  Stream<Uint8List> get stderr => _session.stderr;

  @override
  StreamSink<Uint8List> get stdin => _session.stdin;

  @override
  Future<void> get done => _session.done;

  @override
  int? get exitCode => _session.exitCode;

  @override
  String? get exitSignal => _session.exitSignal?.signalName;

  @override
  void close() => _session.close();
}

final class SshUnixTunnel {
  SshUnixTunnel._(this.remoteSocketPath, this._server, this._openProxy);

  final String remoteSocketPath;
  final ServerSocket _server;
  final SshProxyOpener _openProxy;
  final Set<Socket> _sockets = {};
  final Set<SshProxyChannel> _channels = {};
  final Completer<void> _firstFailure = Completer<void>();
  StreamSubscription<Socket>? _subscription;
  var _closed = false;
  static int _nextDiagnosticId = 0;
  final int _diagnosticId = ++_nextDiagnosticId;

  int get localPort => _server.port;
  Future<void> get firstFailure => _firstFailure.future;

  static Future<SshUnixTunnel> start(
    SSHClient client,
    String remoteSocketPath, {
    Map<String, String> environment = const {},
  }) =>
      startWithOpener(
        remoteSocketPath,
        () async {
          final session = await client.execute(
            CodexDaemon.proxyCommand(remoteSocketPath),
            environment: environment.isEmpty ? null : environment,
          );
          return _SshSessionProxyChannel(session);
        },
      );

  static Future<SshUnixTunnel> startWithOpener(
    String remoteSocketPath,
    SshProxyOpener openProxy,
  ) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final tunnel = SshUnixTunnel._(remoteSocketPath, server, openProxy);
    tunnel._subscription = server.listen((socket) {
      unawaited(tunnel._bridge(socket));
    });
    return tunnel;
  }

  Future<void> _bridge(Socket socket) async {
    if (_closed) {
      socket.destroy();
      return;
    }
    _sockets.add(socket);
    SshProxyChannel? channel;
    StreamSubscription<Uint8List>? toRemote;
    StreamSubscription<Uint8List>? toLocal;
    StreamSubscription<Uint8List>? stderrSubscription;
    try {
      channel = await _openProxy();
      Diagnostics.record('tunnel.open', {'tunnel': _diagnosticId});
      if (_closed) return;
      _channels.add(channel);

      const diagnosticLimit = 1200;
      final stderr = <int>[];
      final stderrDone = Completer<void>();
      void completeStderr() {
        if (!stderrDone.isCompleted) stderrDone.complete();
      }

      stderrSubscription = channel.stderr.listen(
        (chunk) {
          final remaining = diagnosticLimit - stderr.length;
          if (remaining > 0) stderr.addAll(chunk.take(remaining));
        },
        onDone: completeStderr,
        onError: (_, __) => completeStderr(),
        cancelOnError: true,
      );

      final localDone = Completer<void>();
      final remoteDone = Completer<void>();
      toRemote = socket.listen(
        channel.stdin.add,
        onDone: () {
          Diagnostics.record('tunnel.localDone', {'tunnel': _diagnosticId});
          if (!localDone.isCompleted) localDone.complete();
        },
        onError: (Object error, StackTrace stackTrace) {
          Diagnostics.record('tunnel.localError', {
            'tunnel': _diagnosticId,
            ...Diagnostics.errorFields(error),
          });
          if (!localDone.isCompleted) localDone.complete();
        },
        cancelOnError: true,
      );
      toLocal = channel.stdout.listen(
        socket.add,
        onDone: () {
          Diagnostics.record('tunnel.stdoutDone', {'tunnel': _diagnosticId});
          if (!remoteDone.isCompleted) remoteDone.complete();
        },
        onError: remoteDone.completeError,
        cancelOnError: true,
      );
      unawaited(
        channel.done.then(
          (_) {
            Diagnostics.record('tunnel.channelDone', {
              'tunnel': _diagnosticId,
              'exitCode': channel?.exitCode,
              'exitSignal': safeExitSignal(channel?.exitSignal),
            });
            if (!remoteDone.isCompleted) remoteDone.complete();
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!remoteDone.isCompleted) {
              remoteDone.completeError(error, stackTrace);
            }
          },
        ),
      );

      final endedRemotely = await Future.any<bool>([
        localDone.future.then((_) => false),
        remoteDone.future.then((_) => true),
      ]);
      if (endedRemotely) {
        await channel.done;
        await stderrDone.future;
        Diagnostics.record('tunnel.remoteExit', {
          'tunnel': _diagnosticId,
          'closing': _closed,
          'exitCode': channel.exitCode,
          'exitSignal': safeExitSignal(channel.exitSignal),
          ...proxyDiagnosticFields(utf8.decode(stderr, allowMalformed: true)),
        });
        throw _proxyClosedException(channel, stderr);
      }
    } catch (error, stackTrace) {
      Diagnostics.record('tunnel.error', {
        'tunnel': _diagnosticId,
        'closing': _closed,
        ...Diagnostics.errorFields(error),
      });
      debugPrint('Remote Codex Unix tunnel failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!_closed && !_firstFailure.isCompleted) {
        _firstFailure.completeError(error, stackTrace);
      }
    } finally {
      await toRemote?.cancel();
      await toLocal?.cancel();
      await stderrSubscription?.cancel();
      try {
        await channel?.stdin.close();
      } catch (_) {
        // The remote process may have already closed the SSH channel.
      }
      socket.destroy();
      channel?.close();
      _sockets.remove(socket);
      if (channel != null) _channels.remove(channel);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    Diagnostics.record('tunnel.closeRequested', {'tunnel': _diagnosticId});
    _closed = true;
    await _subscription?.cancel();
    await _server.close();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    for (final channel in _channels.toList()) {
      channel.close();
    }
    _sockets.clear();
    _channels.clear();
  }
}

String? safeExitSignal(String? signal) => switch (signal) {
      null => null,
      'ABRT' ||
      'ALRM' ||
      'FPE' ||
      'HUP' ||
      'ILL' ||
      'INT' ||
      'KILL' ||
      'PIPE' ||
      'QUIT' ||
      'SEGV' ||
      'TERM' ||
      'USR1' ||
      'USR2' =>
        signal,
      _ => 'other',
    };

Map<String, Object?> proxyDiagnosticFields(String stderr) => {
      'stderrPresent': stderr.isNotEmpty,
      'reason': stderr.contains('downstream closed before WebSocket upgrade')
          ? 'downstream_closed_before_upgrade'
          : stderr.contains('Connection refused')
              ? 'proxy_connection_refused'
              : stderr.contains('No such file or directory')
                  ? 'proxy_socket_or_file_missing'
                  : 'proxy_exit_unknown',
      'reasonEvidence': 'proxy_stderr_classification',
    };

CodexProxyException _proxyClosedException(
  SshProxyChannel channel,
  List<int> stderr,
) {
  final metadata = <String>[
    if (channel.exitCode != null) 'exit code ${channel.exitCode}',
    if (channel.exitSignal != null) 'signal ${channel.exitSignal}',
  ];
  final diagnostic = utf8.decode(stderr, allowMalformed: true).trim();
  final suffix = <String>[
    if (metadata.isNotEmpty) metadata.join(' and '),
    if (diagnostic.isNotEmpty) diagnostic,
  ];
  return CodexProxyException(
    'Remote Codex proxy closed before the local RPC connection was ready.'
    '${suffix.isEmpty ? '' : ' ${suffix.join(': ')}'}',
  );
}
