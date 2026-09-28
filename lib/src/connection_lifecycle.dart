import 'dart:async';

import 'package:flutter/widgets.dart';

/// Ignore transient inactive states (dialogs, notification shade, focus changes).
class ConnectionLifecycle extends WidgetsBindingObserver {
  ConnectionLifecycle({required this.onBackground, required this.onForeground});

  final VoidCallback onBackground;
  final Future<void> Function() onForeground;
  bool _background = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      if (_background) return;
      _background = true;
      onBackground();
    } else if (state == AppLifecycleState.resumed && _background) {
      _background = false;
      unawaited(onForeground());
    }
  }
}
