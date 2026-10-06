import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Coalesce default-network callbacks; capability noise is not a disconnect.
class ConnectionNetwork {
  ConnectionNetwork(this.onChanged);
  static const channel = MethodChannel('android_ssh_codex/connection_events');
  final Future<void> Function(bool available) onChanged;
  Timer? _debounce;
  String? _signature;
  bool _disposed = false;
  bool _started = false;

  Future<void> start() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (_started || _disposed) return;
    _started = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'networkChanged') accept(call.arguments);
    });
    try {
      accept(await channel.invokeMethod<Object?>('snapshot'));
    } on PlatformException {
      // Older native hosts may not implement network observation.
    } on MissingPluginException {
      // Non-Android test hosts have no native observer.
    }
  }

  void accept(Object? value) {
    if (_disposed || value is! Map || !value.containsKey('networkPresent')) {
      return;
    }
    final available =
        value['networkPresent'] == true && value['blocked'] != true;
    final signature = '${value['activeNetwork']}:$available';
    if (signature == _signature) return;
    _signature = signature;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      if (!_disposed) unawaited(onChanged(available));
    });
  }

  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    if (_started) {
      channel.setMethodCallHandler(null);
    }
  }
}
