import 'package:flutter/material.dart';

class RemoteFileActions extends InheritedWidget {
  const RemoteFileActions(
      {required this.download, required super.child, super.key});
  final Future<bool> Function(String) download;

  static RemoteFileActions? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RemoteFileActions>();

  @override
  bool updateShouldNotify(RemoteFileActions oldWidget) =>
      download != oldWidget.download;
}

Future<void> showRemoteFileDownload(BuildContext context, String path) async {
  final actions = RemoteFileActions.maybeOf(context);
  if (actions == null) return;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Download remote file?'),
      content: SingleChildScrollView(
          child: SelectableText(
              '$path\n\nMaximum 100 MiB. Choose a save location after downloading.')),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Download')),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Downloading file…')));
  try {
    final saved = await actions.download(path);
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
        SnackBar(content: Text(saved ? 'File saved' : 'Save cancelled')));
  } catch (_) {
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(const SnackBar(
        content: Text(
            'Download failed. Check connection, file path and the 100 MiB limit.')));
  }
}
