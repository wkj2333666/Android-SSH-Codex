import 'package:flutter/widgets.dart';

typedef RemotePortLinkHandler = Future<void> Function(
    BuildContext context, Uri uri, Future<bool> Function(Uri) openBrowser);

/// Only explicit web-link taps use this hook; message text never starts tunnels.
class RemotePortLinkScope extends InheritedWidget {
  const RemotePortLinkScope(
      {required this.onOpen, required super.child, super.key});
  final RemotePortLinkHandler onOpen;
  static RemotePortLinkScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RemotePortLinkScope>();
  @override
  bool updateShouldNotify(RemotePortLinkScope oldWidget) =>
      onOpen != oldWidget.onOpen;
}
