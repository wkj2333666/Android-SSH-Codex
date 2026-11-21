import 'dart:async';

import 'package:android_ssh_codex/src/transport/download_queue.dart';
import 'package:android_ssh_codex/src/transport/file_download.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('serializes downloads, keeps progress, and deduplicates active files',
      () async {
    final first = Completer<SavedDownload>();
    final second = Completer<SavedDownload>();
    final started = <String>[];
    final queue = DownloadQueue((entry, cancellation, update) {
      started.add(entry.path);
      update(const DownloadProgress(1024, 8192, bytesPerSecond: 4096));
      return started.length == 1 ? first.future : second.future;
    }, onChanged: () {});
    addTearDown(queue.dispose);
    queue.enqueue('a', '/first.zip', 'Host A');
    queue.enqueue('a', '/first.zip', 'Host A');
    queue.enqueue('a', '/second.zip', 'Host A');
    expect(started, ['/first.zip']);
    expect(queue.activeCount, 2);
    expect(queue.entries.first.state, DownloadState.queued);
    expect(queue.entries.last.progress.bytesPerSecond, 4096);
    first.complete((name: 'first (1).zip', uri: 'content://media/file/10'));
    await Future<void>.delayed(Duration.zero);
    expect(started, ['/first.zip', '/second.zip']);
    expect(queue.entries.last.name, 'first (1).zip');
    expect(queue.entries.last.state, DownloadState.completed);
    second.completeError(const FileDownloadException('Remote file unreadable'));
    await Future<void>.delayed(Duration.zero);
    expect(queue.activeCount, 0);
    expect(queue.entries.first.error, 'Remote file unreadable');
  });

  test('cancels waiting and running downloads; successful retry uses same host',
      () async {
    var started = 0;
    final never = Completer<SavedDownload>();
    final queue = DownloadQueue((entry, cancellation, _) {
      expect(entry.hostId, 'a');
      if (++started == 1) return cancellation.wait(never.future);
      return Future.value((name: 'a.txt', uri: null));
    }, onChanged: () {});
    addTearDown(queue.dispose);
    queue.enqueue('a', '/a.txt', 'Host A');
    queue.enqueue('b', '/b.txt', 'Host B');
    final active = queue.entries.last;
    final queued = queue.entries.first;
    queue.cancel(queued);
    queue.cancel(active);
    await Future<void>.delayed(Duration.zero);
    expect(queue.activeCount, 0);
    expect(queued.state, DownloadState.cancelled);
    expect(active.state, DownloadState.cancelled);
    expect(started, 1);
    queue.retry(active);
    await Future<void>.delayed(Duration.zero);
    expect(active.state, DownloadState.completed);
    expect(started, 2);
    queue.removeFromHistory(active);
    expect(queue.entries, [queued]);
  });

  test('preserves saved files in history without restarting interrupted jobs',
      () async {
    final hanging = Completer<SavedDownload>();
    final queue = DownloadQueue((entry, cancellation, update) async {
      if (entry.path == '/busy.zip') return cancellation.wait(hanging.future);
      update(const DownloadProgress(20, 20, saving: true));
      return (
        name: 'saved.zip',
        uri: 'content://media/external_primary/downloads/1'
      );
    }, onChanged: () {});
    addTearDown(queue.dispose);
    queue.enqueue('a', '/saved.zip', 'Host A');
    queue.enqueue('a', '/busy.zip', 'Host A');
    await Future<void>.delayed(Duration.zero);
    final restored = DownloadQueue((_, __, ___) {
      fail(
          'An interrupted download should not auto-start after process death.');
    }, onChanged: () {});
    addTearDown(restored.dispose);
    restored.restore(queue.toJson());
    expect(restored.activeCount, 0);
    expect(restored.entries.first.state, DownloadState.failed);
    expect(restored.entries.first.error, contains('Interrupted'));
    expect(restored.entries.last.state, DownloadState.completed);
    expect(restored.entries.last.progress.total, 20);
    expect(restored.entries.last.uri,
        'content://media/external_primary/downloads/1');
  });
}
