import 'dart:convert';
import 'dart:io';

import 'package:android_ssh_codex/src/attachment_media.dart';
import 'package:android_ssh_codex/src/attachments.dart';
import 'package:android_ssh_codex/src/ui/document_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _TextFile implements File {
  @override
  String get path => '/cache/payload.bin';

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async => '<b>原文</b>';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('text is selectable and download uses the original cached file',
      (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final file = _TextFile();
    messenger.setMockMethodCallHandler(Attachments.channel, (call) async {
      expect(call.method, 'saveDownload');
      expect(call.arguments, {'path': file.path, 'name': 'notes.txt'});
      return true;
    });
    addTearDown(
        () => messenger.setMockMethodCallHandler(Attachments.channel, null));
    await tester.pumpWidget(MaterialApp(
      home: DocumentPreview(
          file: file, name: 'notes.txt', kind: DocumentPreviewKind.text),
    ));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SelectableText, '<b>原文</b>'), findsOneWidget);
    await tester.tap(find.byTooltip('Download original'));
    await tester.pumpAndSettle();
    expect(find.text('File saved'), findsOneWidget);
  });
}
