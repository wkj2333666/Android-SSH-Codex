import 'dart:async';

import 'package:android_ssh_codex/src/transport/file_download.dart';
import 'package:android_ssh_codex/src/ui/widgets/markdown_content.dart';
import 'package:android_ssh_codex/src/ui/widgets/remote_file_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('remote text and PDF links open the document preview',
      (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RemoteFileActions(
          download: (_) async => throw StateError('Unexpected download'),
          previewDocument: (path, {onProgress, onReady}) async {
            opened.add(path);
            onReady?.call();
            return true;
          },
          child: const MarkdownContent(
              text: '[Text](notes.txt)\n\n[PDF](sandbox:/mnt/report.PDF)\n\n'
                  '[Archive](/tmp/data.zip)'),
        ),
      ),
    ));
    for (final label in ['Text', 'PDF']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    expect(opened, ['notes.txt', 'sandbox:/mnt/report.PDF']);
    expect(find.text('Download remote file?'), findsNothing);
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(find.text('Download remote file?'), findsOneWidget);
  });

  testWidgets(
      'ordinary Markdown video links open the shared save-capable player',
      (tester) async {
    var plays = 0;
    var downloads = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: RemoteFileActions(
      download: (_) async {
        downloads++;
        return true;
      },
      previewVideo: (path, {onProgress, onReady}) async {
        expect(path, '/remote/a.mp4');
        plays++;
        onReady?.call();
        return true;
      },
      child: const MarkdownContent(text: '[Watch video](/remote/a.mp4)'),
    ))));
    await tester.tap(find.text('Watch video'));
    await tester.pumpAndSettle();
    expect(plays, 1);
    expect(downloads, 0);
    expect(find.text('Download remote file?'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('video loading has progress, cancellation and decoder errors',
      (tester) async {
    final completion = Completer<bool>();
    void Function(DownloadProgress)? update;
    VoidCallback? ready;
    var cancellations = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: RemoteFileActions(
      download: (_) async => false,
      cancelDownload: () => cancellations++,
      previewVideo: (_, {onProgress, onReady}) {
        update = onProgress;
        ready = onReady;
        return completion.future;
      },
      child: Builder(
          builder: (context) => TextButton(
              onPressed: () => showRemoteVideoPreview(context, '/remote/a.mp4'),
              child: const Text('Play'))),
    ))));
    await tester.tap(find.text('Play'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    update!(const DownloadProgress(1048576, 2097152));
    await tester.pump();
    expect(find.text('Loading video'), findsOneWidget);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator))
            .value,
        0.5);
    await tester.tap(find.text('Cancel loading'));
    expect(cancellations, 1);
    ready!();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    completion.completeError(PlatformException(
        code: 'VIDEO_UNSUPPORTED', message: 'Unsupported video codec.'));
    await tester.pumpAndSettle();
    expect(find.text('Unsupported video codec.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('download does not block chat while enqueueing', (tester) async {
    final completion = Completer<void>();
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: RemoteFileActions(
      download: (_) => completion.future,
      child: Builder(
          builder: (context) => Column(children: [
                TextButton(
                  onPressed: () => showRemoteFileDownload(context, '/tmp/file'),
                  child: const Text('Start'),
                ),
                TextButton(
                  onPressed: () => tapped = true,
                  child: const Text('Keep working'),
                ),
              ])),
    ))));
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep working'));
    expect(tapped, isTrue);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    completion
        .completeError(const FileDownloadException('File does not exist.'));
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('File does not exist.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('file links require confirmation and web links stay external',
      (tester) async {
    final downloads = <String>[];
    final web = <Uri>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: RemoteFileActions(
      download: (path) async {
        downloads.add(path);
        return true;
      },
      child: MarkdownContent(
        text: '[Report](sandbox:/mnt/data/report.pdf)',
        openExternalLink: (uri) async {
          web.add(uri);
          return true;
        },
      ),
    ))));
    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    markdown.onTapLink!('Report', 'sandbox:/mnt/data/report.pdf', '');
    await tester.pumpAndSettle();
    expect(downloads, isEmpty);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(downloads, ['sandbox:/mnt/data/report.pdf']);
    expect(find.text('Download remote file?'), findsNothing);
    markdown.onTapLink!('Web', 'https://example.com', '');
    await tester.pumpAndSettle();
    expect(web.single.host, 'example.com');
  });
}
