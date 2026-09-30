import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:dartssh2/dartssh2.dart';

/// Only explicit metadata goes here: never RPC payloads or exception messages.
abstract final class Diagnostics {
  static const channel = MethodChannel('android_ssh_codex/diagnostics');
  static int _pending = 0;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static void record(String event, [Map<String, Object?> fields = const {}]) {
    if (!supported || _pending >= 128) return;
    _pending++;
    unawaited(_record(event, fields));
  }

  static Future<void> _record(String event, Map<String, Object?> fields) async {
    try {
      await channel.invokeMethod<void>('record', {
        'event': event,
        'time': DateTime.now().toUtc().toIso8601String(),
        ...fields,
      });
    } catch (_) {
      // Diagnostics must never affect the connection (including older hosts).
    } finally {
      _pending--;
    }
  }

  static Map<String, Object?> errorFields(Object error) {
    final types = <String>[];
    Object cause = error;
    for (var depth = 0; depth < 8; depth++) {
      types.add(cause.runtimeType.toString());
      final nested = switch (cause) {
        SSHSocketError(:final error) => error,
        SSHInternalError(:final error) => error,
        SSHAuthAbortError(:final reason) => reason,
        _ => null,
      };
      if (nested == null || identical(nested, cause)) break;
      cause = nested;
    }
    final osCode = switch (cause) {
      SocketException(:final osError) => osError?.errorCode,
      OSError(:final errorCode) => errorCode,
      _ => null,
    };
    // errno names below are Android/Linux values, not proof of who reset TCP.
    final reason = switch (cause) {
      TimeoutException() => 'timeout',
      SSHAuthFailError() => 'ssh_authentication_failed',
      SSHHostkeyError() => 'ssh_host_key_rejected',
      SSHChannelOpenError() => 'ssh_channel_open_rejected',
      SSHHandshakeError(message: 'Handshake timed out') =>
        'ssh_handshake_timeout',
      SocketException() ||
      OSError() when Platform.isAndroid || Platform.isLinux =>
        switch (osCode) {
          1 => 'operation_not_permitted',
          13 => 'access_denied',
          32 => 'broken_pipe',
          100 => 'network_down',
          101 => 'network_unreachable',
          102 => 'network_reset',
          103 => 'connection_aborted',
          104 => 'connection_reset',
          110 => 'tcp_timeout',
          111 => 'connection_refused',
          113 => 'host_unreachable',
          _ => 'socket_error_unknown',
        },
      _ => 'unknown',
    };
    return {
      'errorType': error.runtimeType.toString(),
      'errorChain': types,
      'reason': reason,
      'reasonEvidence': reason == 'unknown' ? 'unavailable' : 'exception',
      if (osCode != null) 'osCode': osCode,
      if (cause is SSHChannelOpenError) 'sshChannelCode': cause.code,
    };
  }

  static Future<bool> export() async =>
      await channel.invokeMethod<bool>('export') ?? false;
}
