import 'dart:io';

import 'package:android_ssh_codex/src/attachments.dart';
import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/tasks/task_message_queue.dart';
import 'package:android_ssh_codex/src/transport/attachment_upload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(Attachments.channel, null));

  test('picker returns a cached file reference and handles cancellation',
      () async {
    messenger.setMockMethodCallHandler(
        Attachments.channel,
        (call) async => {
              'name': 'photo.png',
              'path': '/cache/picked.bin',
              'size': 3,
              'isImage': true,
            });
    final image = await Attachments.pick(image: true);
    expect(image!.isImage, true);
    expect(image.path, '/cache/picked.bin');
    expect(image.size, 3);
    messenger.setMockMethodCallHandler(
        Attachments.channel, (call) async => null);
    expect(await Attachments.pick(image: false), isNull);
  });

  test('attachment count and 1 GiB per-file limits apply before upload', () {
    const empty =
        LocalAttachment(name: 'file', path: '/cache/a', size: 0, isImage: false);
    expect(
        () => Attachments.validate(List.filled(5, empty)), throwsArgumentError);
    const large = LocalAttachment(
        name: 'file',
        path: '/cache/b',
        size: Attachments.maxFileBytes + 1,
        isImage: false);
    expect(() => Attachments.validate([large]), throwsArgumentError);
    const allowed = LocalAttachment(
        name: 'file',
        path: '/cache/c',
        size: Attachments.maxFileBytes,
        isImage: false);
    expect(
        () => Attachments.validate([allowed, allowed, empty]), returnsNormally);
    expect(() => Attachments.validate(List.filled(4, allowed)), returnsNormally);
  });

  test('remote upload command never interpolates shell syntax from filename',
      () {
    final command = attachmentUploadCommand('0123456789abcdef0123456789abcdef',
        r'../../$(touch injected);"file.png');
    expect(command, isNot(contains(r'$(')));
    expect(command, isNot(contains('../')));
    expect(command, contains('umask 077'));
    expect(command, startsWith('/bin/sh -c '));
    expect(command, contains('trap'));
    expect(
        () => attachmentUploadCommand('../bad', 'file'), throwsArgumentError);
  });

  test('attachment upload source streams from disk and detects changes',
      () async {
    final directory = await Directory.systemTemp.createTemp('attachment-test-');
    final file = File('${directory.path}/payload');
    addTearDown(() => directory.delete(recursive: true));
    await file.writeAsBytes(List.generate(200000, (index) => index % 251));
    final progress = <int>[];
    final chunks = await attachmentFileStream(file,
            expectedSize: 200000, onProgress: progress.add)
        .toList();
    expect(chunks.length, greaterThan(1));
    expect(chunks.fold<int>(0, (sum, chunk) => sum + chunk.length), 200000);
    expect(progress.last, 200000);
    await expectLater(
        attachmentFileStream(file, expectedSize: 199999).drain<void>(),
        throwsStateError);
  });

  test('attachment-only message and queued steer preserve image paths', () {
    final text = attachmentPrompt(
        '', const [RemoteAttachment(path: '/remote/photo.png', isImage: true)]);
    expect(text, contains('/remote/photo.png'));
    final queue = TaskMessageQueue<QueuedTaskMessage>();
    queue.enqueue(
        'thread',
        QueuedTaskMessage(
            id: '1', text: text, imagePaths: const ['/remote/photo.png']));
    expect(queue.take('thread')!.imagePaths, ['/remote/photo.png']);
  });
}
