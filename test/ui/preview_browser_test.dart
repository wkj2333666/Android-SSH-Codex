import 'dart:convert';
import 'dart:io';

import 'package:android_ssh_codex/src/ui/preview_browser.dart';
import 'package:android_ssh_codex/src/ui/port_forwards_view.dart';
import 'package:android_ssh_codex/src/ui/widgets/inline_attachment_image.dart';
import 'package:android_ssh_codex/src/tasks/message_attachments.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('forwarded pages prefer in-app and retain external fallback', () async {
    final uri = Uri.parse('http://127.0.0.1:3000/path?q=1#x');
    var externalCount = 0;
    Future<bool> external(Uri value) async {
      expect(value, uri);
      externalCount++;
      return true;
    }

    expect(await openForwardedPage(uri, external, inApp: (_) async => true),
        isTrue);
    expect(externalCount, 0);
    expect(await openForwardedPage(uri, external, inApp: (_) async => false),
        isTrue);
    expect(
        await openForwardedPage(uri, external,
            inApp: (_) async => throw PlatformException(code: 'UNAVAILABLE')),
        isTrue);
    expect(externalCount, 2);
  });

  test('native image preview uses a private file and releases it after closing',
      () async {
    final root = await Directory.systemTemp.createTemp('preview-test-');
    addTearDown(() => root.delete(recursive: true));
    String? previewPath;
    final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PreviewBrowser.channel, (call) async {
      if (call.method == 'cacheDirectory') return root.path;
      expect(call.method, 'openImage');
      previewPath = (call.arguments as Map)['path'] as String;
      expect(await File(previewPath!).readAsBytes(), bytes);
      expect(File(previewPath!).parent.parent.path, root.path);
      return true;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PreviewBrowser.channel, null));
    expect(await PreviewBrowser.openImage(bytes, 'Photo'), isTrue);
    expect(await File(previewPath!).exists(), isFalse);
  });

  test('in-app browser accepts only mapped HTTP(S) loopback URLs', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PreviewBrowser.channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PreviewBrowser.channel, null));
    expect(
        await PreviewBrowser.openPage(
            Uri.parse('http://127.0.0.1:3100/path?q=1#x')),
        isTrue);
    expect(calls.single.arguments, {'url': 'http://127.0.0.1:3100/path?q=1#x'});
    for (final url in [
      'file:///etc/passwd',
      'javascript:alert(1)',
      'https://example.com/',
      'http://user:pass@127.0.0.1/'
    ]) {
      await expectLater(
          PreviewBrowser.openPage(Uri.parse(url)), throwsArgumentError);
    }
    expect(calls, hasLength(1));
  });

  testWidgets('all inline images open a full-screen viewer with explicit zoom',
      (tester) async {
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=';
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: InlineAttachmentImage(
      attachment:
          const MessageAttachment(path: '/remote/image.png', isImage: true),
      loadImage: (_) async => base64Decode(png),
    ))));
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('image-preview-page')), findsOneWidget);
    final viewer =
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    expect(viewer.maxScale, greaterThanOrEqualTo(8));
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump();
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(),
        greaterThan(1));
    await tester.tap(find.byTooltip('Reset zoom'));
    await tester.pump();
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 1);
    expect(tester.takeException(), isNull);
  });
}
