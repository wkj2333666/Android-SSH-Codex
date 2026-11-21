import 'dart:async';

import 'package:android_ssh_codex/src/transport/download_queue.dart';
import 'package:android_ssh_codex/src/transport/file_download.dart';
import 'package:android_ssh_codex/src/ui/downloads_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows live download progress and opens completed files',
      (tester) async {
    final saved = Completer<SavedDownload>();
    final nativeCalls = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(PublicDownloadStorage.channel, (call) async {
      nativeCalls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(PublicDownloadStorage.channel, null));
    late void Function(DownloadProgress) update;
    final queue = DownloadQueue((_, __, progress) {
      update = progress;
      return saved.future;
    }, onChanged: () {});
    addTearDown(queue.dispose);
    await tester.pumpWidget(MaterialApp(
        home: DownloadsView(queue: queue, retry: (_) async {})));
    expect(find.text('No downloads yet'), findsOneWidget);
    queue.enqueue('pi', '/tmp/data.zip', 'Pi');
    update(const DownloadProgress(1048576, 2097152, bytesPerSecond: 4194304));
    await tester.pumpAndSettle();
    expect(find.text('Downloads/RemoteCodex'), findsOneWidget);
    expect(find.textContaining('50% · 4.00 MiB/s'), findsOneWidget);
    expect(find.byTooltip('Cancel download'), findsOneWidget);

    saved.complete((
      name: 'data (1).zip',
      uri: 'content://media/external_primary/downloads/1'
    ));
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.tap(find.text('data (1).zip'));
    await tester.tap(find.byTooltip('Open downloads folder'));
    expect(nativeCalls.map((call) => call.method), ['openFile', 'openFolder']);
    expect(nativeCalls.first.arguments,
        {'uri': 'content://media/external_primary/downloads/1'});
    await tester.pumpWidget(const SizedBox());
  });
}
