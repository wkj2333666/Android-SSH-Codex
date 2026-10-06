import 'dart:async';

import 'package:android_ssh_codex/src/transport/file_download.dart';
import 'package:android_ssh_codex/src/ui/widgets/markdown_content.dart';
import 'package:android_ssh_codex/src/ui/widgets/remote_file_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('download reports progress and specific failure', (tester) async {
    final completion = Completer<bool>();
    void Function(DownloadProgress)? update;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: RemoteFileActions(
      download: (_) async => false,
      downloadWithProgress: (_, {onProgress}) {
        update = onProgress;
        return completion.future;
      },
      child: Builder(builder: (context) => TextButton(
        onPressed: () => showRemoteFileDownload(context, '/tmp/file'),
        child: const Text('Start'),
      )),
    ))));
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    update!(const DownloadProgress(1048576, 2097152));
    await tester.pump();
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.5);
    expect(find.text('1.00 MiB received · 50%'), findsOneWidget);
    completion.completeError(const FileDownloadException('File does not exist.'));
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
    expect(find.text('File saved'), findsOneWidget);
    markdown.onTapLink!('Web', 'https://example.com', '');
    await tester.pumpAndSettle();
    expect(web.single.host, 'example.com');
  });
}
