import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../transport/file_download.dart';

class RemoteFileActions extends InheritedWidget {
  const RemoteFileActions(
      {required this.download,
      this.downloadWithProgress,
      required super.child,
      super.key});
  final Future<bool> Function(String) download;
  final Future<bool> Function(String,
      {void Function(DownloadProgress)? onProgress})? downloadWithProgress;

  static RemoteFileActions? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RemoteFileActions>();

  @override
  bool updateShouldNotify(RemoteFileActions oldWidget) =>
      download != oldWidget.download ||
      downloadWithProgress != oldWidget.downloadWithProgress;
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
  final progress = ValueNotifier(const DownloadProgress(0, null));
  var finished = false;
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Download file'),
        content: ValueListenableBuilder<DownloadProgress>(
          valueListenable: progress,
          builder: (context, value, _) {
            final total = value.total;
            final fraction = total != null && total > 0
                ? (value.received / total).clamp(0.0, 1.0)
                : null;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: value.saving ? null : fraction),
                const SizedBox(height: 12),
                Text(value.saving
                    ? 'Choose a location, then saving…'
                    : '${(value.received / 1048576).toStringAsFixed(2)} MiB received'
                        '${fraction == null ? "" : " · ${(fraction * 100).toStringAsFixed(0)}%"}'),
              ],
            );
          },
        ),
      ),
    ),
  );
  unawaited(navigator.push(route));
  try {
    final saved = actions.downloadWithProgress == null
        ? await actions.download(path)
        : await actions.downloadWithProgress!(path, onProgress: (value) {
            if (!finished) progress.value = value;
          });
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
        SnackBar(content: Text(saved ? 'File saved' : 'Save cancelled')));
  } catch (error) {
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger
        .showSnackBar(SnackBar(content: Text(downloadErrorMessage(error))));
  } finally {
    finished = true;
    if (route.isActive) navigator.removeRoute(route);
    // Route widgets are disposed after removal; do not dispose their notifier
    // while ValueListenableBuilder is still listening.
    WidgetsBinding.instance.addPostFrameCallback((_) => progress.dispose());
  }
}

String downloadErrorMessage(Object error) {
  if (error is FileDownloadException) return error.message;
  if (error is TimeoutException) {
    return 'Download timed out. Check the connection and retry.';
  }
  if (error is FileSystemException) {
    return 'Phone temporary storage could not be written. Check free space.';
  }
  if (error is PlatformException) {
    return 'Could not save on the phone (${error.code}). Choose another location.';
  }
  if (error is StateError) return 'Download failed: ${error.message}';
  return 'Download failed (${error.runtimeType}). Check the SSH connection and retry.';
}
