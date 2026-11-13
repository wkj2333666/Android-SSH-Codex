import 'package:android_ssh_codex/src/ui/widgets/codex_directive_content.dart';
import 'package:android_ssh_codex/src/ui/widgets/remote_file_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _path = '/remote/.codex/visualizations/grasp audit.html';
const _directive =
    '\uE200visualize\uE202{"path":"$_path","mode":"wide"}\uE201';

void main() {
  test('only standalone native HTML directives become visualization cards', () {
    final parsed = parseCodexDirectiveContent('Report\n\n$_directive\n');
    expect(parsed.markdown.trim(), 'Report');
    expect(parsed.visualizations.single.path, _path);
    for (final example in [
      '```\n$_directive\n```',
      '    $_directive',
      'Example: $_directive',
      _directive.replaceFirst('/remote/', 'https://example.test/'),
      _directive.replaceFirst('.html', '.sh'),
    ]) {
      expect(parseCodexDirectiveContent(example).markdown, example);
      expect(parseCodexDirectiveContent(example).visualizations, isEmpty);
    }
  });

  testWidgets('visualization only opens after a tap', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RemoteFileActions(
          download: (_) async => throw StateError('Unexpected download'),
          previewVisualization: (path, {onProgress, onReady}) async {
            opened.add(path);
            onReady?.call();
            return true;
          },
          child: const CodexDirectiveContent(text: _directive),
        ),
      ),
    ));
    expect(opened, isEmpty);
    expect(find.text('grasp audit.html'), findsOneWidget);
    await tester.tap(find.text('Open visualization'));
    await tester.pumpAndSettle();
    expect(opened, [_path]);
  });
}
