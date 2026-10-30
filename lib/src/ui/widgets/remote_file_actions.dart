import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../transport/file_download.dart';
import '../../transport/resumable_download.dart';

class RemoteFileActions extends InheritedWidget {
  const RemoteFileActions(
      {required this.download,
      this.downloadWithProgress,
      this.previewVideo,
      this.cancelDownload,
      required super.child,
      super.key});
  final Future<bool> Function(String) download;
  final VoidCallback? cancelDownload;
  final Future<bool> Function(String,
      {void Function(DownloadProgress)? onProgress})? downloadWithProgress;
  final Future<bool> Function(String,
      {void Function(DownloadProgress)? onProgress,
      VoidCallback? onReady})? previewVideo;

  static RemoteFileActions? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RemoteFileActions>();

  @override
  bool updateShouldNotify(RemoteFileActions oldWidget) =>
      download != oldWidget.download ||
      downloadWithProgress != oldWidget.downloadWithProgress ||
      previewVideo != oldWidget.previewVideo ||
      cancelDownload != oldWidget.cancelDownload;
}

/// Only a tap starts an SSH transfer. Videos are streamed to bounded temporary
/// disk storage, then opened in the phone's player without a save-location step.
Future<void> showRemoteVideoPreview(BuildContext context, String path) async {
  final actions = RemoteFileActions.maybeOf(context);
  final preview = actions?.previewVideo;
  if (preview == null) return;
  final cancel = actions?.cancelDownload;
  final messenger = ScaffoldMessenger.of(context);
  final progress = ValueNotifier(const DownloadProgress(0, null));
  var finished = false;
  var ready = false;
  final navigator = Navigator.of(context, rootNavigator: true);
  late final DialogRoute<void> route;
  void hideLoading() {
    ready = true;
    if (navigator.mounted && route.isActive) navigator.removeRoute(route);
  }
  route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Loading video'),
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
                LinearProgressIndicator(
                    value: value.verifying || value.reconnecting ? null : fraction),
                const SizedBox(height: 12),
                Text('${(value.received / 1048576).toStringAsFixed(2)} MiB received'
                    '${fraction == null ? "" : " · ${(fraction * 100).toStringAsFixed(0)}%"}'),
                if (value.reconnecting)
                  const Text('Connection interrupted. Reconnecting and resuming…'),
                if (value.verifying) const Text('Verifying file integrity…'),
                if (cancel != null)
                  TextButton(
                      onPressed: cancel,
                      child: const Text('Cancel loading')),
              ],
            );
          },
        ),
      ),
    ),
  );
  unawaited(navigator.push(route));
  try {
    await preview(path,
        onProgress: (value) {
          if (!finished && !ready) progress.value = value;
        },
        onReady: hideLoading);
  } catch (error) {
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
        content: Text(error is PlatformException
            ? error.message ?? 'Video playback failed (${error.code}).'
            : downloadErrorMessage(error))));
  } finally {
    finished = true;
    hideLoading();
    WidgetsBinding.instance.addPostFrameCallback((_) => progress.dispose());
  }
}

class RemoteVideoPreview extends StatelessWidget {
  const RemoteVideoPreview({required this.path, this.label, super.key});
  final String path;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final actions = RemoteFileActions.maybeOf(context);
    final playable = actions?.previewVideo != null;
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 280,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (playable)
          Material(
            color: colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => unawaited(showRemoteVideoPreview(context, path)),
              child: SizedBox(
                height: 158,
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.play_circle_outline, size: 48, color: colors.primary),
                    const Text('Play video'),
                    if (label?.isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(label!, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                  ]),
                ),
              ),
            ),
          ),
        if (actions != null)
          TextButton.icon(
            onPressed: () => unawaited(showRemoteFileDownload(context, path)),
            icon: const Icon(Icons.download_outlined),
            label: const Text('Download video'),
          ),
      ]),
    );
  }
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
              '$path\n\nMaximum 1 GiB. Choose a save location after downloading.')),
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
                LinearProgressIndicator(
                    value: value.saving || value.verifying || value.reconnecting
                        ? null
                        : fraction),
                const SizedBox(height: 12),
                Text(value.saving
                    ? 'Choose a location, then saving…'
                    : '${(value.received / 1048576).toStringAsFixed(2)} MiB received'
                        '${fraction == null ? "" : " · ${(fraction * 100).toStringAsFixed(0)}%"}'),
                if (value.reconnecting)
                  const Text(
                      'Connection interrupted. Reconnecting and resuming…'),
                if (value.verifying) const Text('Verifying file integrity…'),
                if (!value.verifying &&
                    !value.reconnecting &&
                    value.bytesPerSecond != null)
                  Text(
                      '${(value.bytesPerSecond! / 1048576).toStringAsFixed(2)} MiB/s'),
                if (actions.cancelDownload != null && !value.saving)
                  TextButton(
                      onPressed: actions.cancelDownload,
                      child: const Text('Cancel download')),
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
  if (error is DownloadCancelled) return 'Download cancelled.';
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
