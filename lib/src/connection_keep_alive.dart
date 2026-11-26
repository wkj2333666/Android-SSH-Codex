import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'diagnostics.dart';

/// Serializes native starts/stops so a slow start cannot outlive disconnect.
class ConnectionKeepAlive {
  static const channel = MethodChannel('android_ssh_codex/connection_service');
  Future<void> _pending = Future.value();
  bool _enabled = false;
  bool _downloadMode = false;

  bool get isEnabled => _enabled;

  Future<void> setEnabled(
    bool enabled, {
    bool verifyNative = false,
    bool downloadActive = false,
  }) {
    final operation = _pending.then((_) async {
      if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
      if (_enabled == enabled && _downloadMode == downloadActive) {
        if (!enabled || !verifyNative) return;
        if (await channel.invokeMethod<bool>('status') == true) return;
        _enabled = false;
      }
      Diagnostics.record('keepAlive.request', {
        'enabled': enabled,
        'downloadActive': downloadActive,
      });
      final notifications = await channel.invokeMethod<bool>(
        enabled ? 'start' : 'stop',
        enabled ? {'downloadActive': downloadActive} : null,
      );
      _enabled = enabled;
      _downloadMode = enabled && downloadActive;
      Diagnostics.record('keepAlive.result', {
        'enabled': enabled,
        'downloadActive': downloadActive,
        'notifications': notifications,
      });
      if (enabled && notifications == false) {
        throw StateError('Background connection service is running, but '
            'notifications are disabled. Enable notifications in Android settings.');
      }
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }
}
