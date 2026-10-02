import 'package:android_ssh_codex/src/ui/widgets/markdown_content.dart';
import 'package:android_ssh_codex/src/ui/widgets/remote_file_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
