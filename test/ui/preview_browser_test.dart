import 'dart:convert';

import 'package:android_ssh_codex/src/ui/preview_browser.dart';
import 'package:android_ssh_codex/src/ui/widgets/inline_attachment_image.dart';
import 'package:android_ssh_codex/src/tasks/message_attachments.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('in-app browser accepts only mapped HTTP(S) loopback URLs', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PreviewBrowser.channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PreviewBrowser.channel, null));
    expect(await PreviewBrowser.openPage(Uri.parse('http://127.0.0.1:3100/path?q=1#x')), isTrue);
    expect(calls.single.arguments, {'url': 'http://127.0.0.1:3100/path?q=1#x'});
    for (final url in ['file:///etc/passwd', 'javascript:alert(1)', 'https://example.com/', 'http://user:pass@127.0.0.1/']) {
      expect(() => PreviewBrowser.openPage(Uri.parse(url)), throwsArgumentError);
    }
    expect(calls, hasLength(1));
  });

  testWidgets('all inline images open a full-screen viewer with explicit zoom', (tester) async {
    const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=';
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: InlineAttachmentImage(
      attachment: const MessageAttachment(path: '/remote/image.png', isImage: true),
      loadImage: (_) async => base64Decode(png),
    ))));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('image-preview-page')), findsOneWidget);
    final viewer = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    expect(viewer.maxScale, greaterThanOrEqualTo(8));
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump();
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(), greaterThan(1));
    await tester.tap(find.byTooltip('Reset zoom'));
    await tester.pump();
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 1);
    expect(tester.takeException(), isNull);
  });
}
