import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

  static Map<String, Object?> errorFields(Object error) => {
        'errorType': error.runtimeType.toString(),
        if (error is SocketException) 'osCode': error.osError?.errorCode,
      };

  static Future<bool> export() async =>
      await channel.invokeMethod<bool>('export') ?? false;
}
