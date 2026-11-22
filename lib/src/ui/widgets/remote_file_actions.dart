import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../transport/download_queue.dart';
import '../../transport/file_download.dart';
import '../../transport/resumable_download.dart';

class RemoteFileActions extends InheritedWidget {
  const RemoteFileActions(
      {required this.download,
      this.previewVideo,
      this.previewVisualization,
      this.previewDocument,
      this.documentWorkingDirectory,
      this.cancelDownload,
      required super.child,
      super.key});
  final Future<void> Function(String) download;
  final VoidCallback? cancelDownload;
  final RemoteFilePreview? previewVideo;
  final RemoteFilePreview? previewVisualization;
  final RemoteFilePreview? previewDocument;
  final String? documentWorkingDirectory;

  static RemoteFileActions? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RemoteFileActions>();

  @override
  bool updateShouldNotify(RemoteFileActions oldWidget) =>
      download != oldWidget.download ||
      previewVideo != oldWidget.previewVideo ||
      previewVisualization != oldWidget.previewVisualization ||
      previewDocument != oldWidget.previewDocument ||
      documentWorkingDirectory != oldWidget.documentWorkingDirectory ||
      cancelDownload != oldWidget.cancelDownload;
}

typedef RemoteFilePreview = Future<bool> Function(String path,
    {void Function(DownloadProgress)? onProgress, VoidCallback? onReady});

/// Only a tap starts an SSH transfer. Videos are streamed to bounded temporary
/// disk storage, then opened in the phone's player without a save-location step.
Future<void> showRemoteVideoPreview(BuildContext context, String path) =>
    _showRemotePreview(context, path, _PreviewKind.video);

Future<void> showRemoteVisualization(BuildContext context, String path) =>
    _showRemotePreview(context, path, _PreviewKind.visualization);

Future<void> showRemoteDocument(BuildContext context, String path) =>
    _showRemotePreview(context, path, _PreviewKind.document);

enum _PreviewKind { video, visualization, document }

Future<void> _showRemotePreview(
    BuildContext context, String path, _PreviewKind kind) async {
  final actions = RemoteFileActions.maybeOf(context);
  final preview = switch (kind) {
    _PreviewKind.video => actions?.previewVideo,
    _PreviewKind.visualization => actions?.previewVisualization,
    _PreviewKind.document => actions?.previewDocument,
  };
  if (preview == null) return;
  final documentCwd = actions?.documentWorkingDirectory;
  final downloadPath = kind == _PreviewKind.document && documentCwd != null
      ? remoteFilePath(path, documentCwd)
      : null;
  final failure = switch (kind) {
    _PreviewKind.video => 'Video playback failed',
    _PreviewKind.visualization => 'Could not open visualization',
    _PreviewKind.document => 'Could not open document',
  };
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
        title: Text('Loading ${kind.name}'),
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
                    value:
                        value.checking || value.reconnecting ? null : fraction),
                const SizedBox(height: 12),
                Text(
                    '${(value.received / 1048576).toStringAsFixed(2)} MiB received'
                    '${fraction == null ? "" : " · ${(fraction * 100).toStringAsFixed(0)}%"}'),
                if (value.reconnecting)
                  const Text(
                      'Connection interrupted. Reconnecting and resuming…'),
                if (value.checking) const Text('Checking remote file…'),
                if (cancel != null)
                  TextButton(
                      onPressed: cancel, child: const Text('Cancel loading')),
              ],
            );
          },
        ),
      ),
    ),
  );
  unawaited(navigator.push(route));
  try {
    final opened = await preview(path, onProgress: (value) {
      if (!finished && !ready) progress.value = value;
    }, onReady: hideLoading);
    if (kind != _PreviewKind.video && !opened) throw StateError(failure);
  } catch (error) {
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
        action: kind == _PreviewKind.document &&
                error is! DownloadCancelled &&
                (documentCwd == null || downloadPath != null)
            ? SnackBarAction(
                label: 'Download',
                onPressed: () {
                  if (context.mounted) {
                    unawaited(showRemoteFileDownload(
                        context,
                        downloadPath == null
                            ? path
                            : Uri(path: downloadPath).toString()));
                  }
                },
              )
            : null,
        content: Text(error is PlatformException
            ? error.message ?? '$failure (${error.code}).'
            : kind != _PreviewKind.video && error is StateError
                ? error.message
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
                    Icon(Icons.play_circle_outline,
                        size: 48, color: colors.primary),
                    const Text('Play video'),
                    if (label?.isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(label!,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
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
              '$path\n\nSaves to ${PublicDownloadStorage.location} in the background. Maximum 1 GiB.')),
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
  try {
    await actions.download(path);
  } catch (error) {
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger
        .showSnackBar(SnackBar(content: Text(downloadErrorMessage(error))));
  }
}
