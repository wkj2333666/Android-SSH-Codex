import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../transport/download_queue.dart';

void showDownloads(BuildContext context, AppController controller) {
  unawaited(Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => DownloadsView(
        queue: controller.downloadQueue,
        retry: controller.retryDownload,
      ),
    ),
  ));
}

class DownloadsAction extends StatelessWidget {
  const DownloadsAction({required this.controller, super.key});
  final AppController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller.downloadQueue,
        builder: (context, _) {
          final count = controller.downloadQueue.activeCount;
          return IconButton(
            tooltip: 'Downloads',
            icon: Badge(
              isLabelVisible: count > 0,
              label: Text('$count'),
              child: const Icon(Icons.download_outlined),
            ),
            onPressed: () => showDownloads(context, controller),
          );
        },
      );
}

class DownloadsView extends StatelessWidget {
  const DownloadsView({required this.queue, required this.retry, super.key});
  final DownloadQueue queue;
  final Future<void> Function(DownloadEntry) retry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          IconButton(
            tooltip: 'Open downloads folder',
            onPressed: () => _run(context, PublicDownloadStorage.showFolder),
            icon: const Icon(Icons.folder_open_outlined),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: queue,
        builder: (context, _) {
          final entries = queue.entries;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Text(PublicDownloadStorage.location),
              ),
              const Divider(height: 1),
              Expanded(
                child: entries.isEmpty
                    ? const Center(child: Text('No downloads yet'))
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (context, index) =>
                            _entry(context, entries[index]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _entry(BuildContext context, DownloadEntry entry) {
    final progress = entry.progress;
    final uri = entry.uri;
    final total = progress.total;
    final fraction = total == null || total <= 0
        ? null
        : (progress.received / total).clamp(0.0, 1.0);
    final details = switch (entry.state) {
      DownloadState.queued => 'Waiting in queue',
      DownloadState.transferring when progress.reconnecting =>
        'Reconnecting · ${_size(progress.received)} received',
      DownloadState.transferring when progress.verifying =>
        total == null ? 'Preparing download…' : 'Verifying file…',
      DownloadState.transferring => '${_size(progress.received)}'
          '${total == null ? "" : " / ${_size(total)}"}'
          '${fraction == null ? "" : " · ${(fraction * 100).toStringAsFixed(0)}%"}'
          '${progress.bytesPerSecond == null ? "" : " · ${_size(progress.bytesPerSecond!)}/s"}',
      DownloadState.saving => 'Saving to Downloads/RemoteCodex…',
      DownloadState.completed =>
        total == null ? 'Complete' : 'Complete · ${_size(total)}',
      DownloadState.failed => entry.error ?? 'Download failed',
      DownloadState.cancelled => 'Cancelled',
    };
    return ListTile(
      key: ObjectKey(entry),
      leading: Icon(entry.state == DownloadState.completed
          ? Icons.insert_drive_file_outlined
          : Icons.download_outlined),
      title: Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${entry.hostLabel} · $details'),
          if (entry.state == DownloadState.transferring ||
              entry.state == DownloadState.saving)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 4),
              child: LinearProgressIndicator(
                value: progress.verifying ||
                        progress.reconnecting ||
                        progress.saving
                    ? null
                    : fraction,
              ),
            ),
        ],
      ),
      onTap: entry.state != DownloadState.completed
          ? null
          : () => _run(
              context,
              uri == null
                  ? PublicDownloadStorage.showFolder
                  : () => PublicDownloadStorage.open(uri)),
      trailing: entry.canCancel
          ? IconButton(
              tooltip: 'Cancel download',
              icon: const Icon(Icons.close),
              onPressed: () => queue.cancel(entry),
            )
          : entry.active
              ? null
              : PopupMenuButton<String>(
                  tooltip: 'Download actions',
                  onSelected: (action) {
                    switch (action) {
                      case 'retry':
                        _run(context, () => retry(entry));
                      case 'folder':
                        _run(context, PublicDownloadStorage.showFolder);
                      case 'remove':
                        queue.removeFromHistory(entry);
                    }
                  },
                  itemBuilder: (_) => [
                    if (entry.canRetry)
                      const PopupMenuItem(value: 'retry', child: Text('Retry')),
                    if (entry.state == DownloadState.completed)
                      const PopupMenuItem(
                        value: 'folder',
                        child: Text('Show in Downloads'),
                      ),
                    const PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove from history'),
                    ),
                  ],
                ),
    );
  }

  Future<void> _run(
      BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(downloadErrorMessage(error))));
    }
  }

  String _size(num bytes) => bytes < 1024
      ? '${bytes.toStringAsFixed(0)} B'
      : bytes < 1048576
          ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
          : '${(bytes / 1048576).toStringAsFixed(2)} MiB';
}
