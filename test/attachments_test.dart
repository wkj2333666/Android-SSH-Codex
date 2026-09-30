import 'dart:typed_data';

import 'package:android_ssh_codex/src/attachments.dart';
import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/tasks/task_message_queue.dart';
import 'package:android_ssh_codex/src/transport/attachment_upload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(Attachments.channel, null));

  test('picker returns image bytes and handles cancellation', () async {
    messenger.setMockMethodCallHandler(Attachments.channel, (call) async => {
      'name': 'photo.png', 'bytes': Uint8List.fromList([1, 2, 3]), 'isImage': true,
    });
    final image = await Attachments.pick(image: true);
    expect(image!.isImage, true);
    expect(image.bytes, [1, 2, 3]);
    messenger.setMockMethodCallHandler(Attachments.channel, (call) async => null);
    expect(await Attachments.pick(image: false), isNull);
  });

  test('attachment count and memory limits apply before upload', () {
    final empty = LocalAttachment(name: 'file', bytes: Uint8List(0), isImage: false);
    expect(() => Attachments.validate(List.filled(5, empty)), throwsArgumentError);
    final large = LocalAttachment(name: 'file', bytes: Uint8List(Attachments.maxFileBytes + 1), isImage: false);
    expect(() => Attachments.validate([large]), throwsArgumentError);
    final allowed = LocalAttachment(name: 'file', bytes: Uint8List(Attachments.maxFileBytes), isImage: false);
    expect(() => Attachments.validate([allowed, allowed, empty]), returnsNormally);
    expect(() => Attachments.validate([allowed, allowed, allowed]), throwsArgumentError);
  });

  test('remote upload command never interpolates shell syntax from filename', () {
    final command = attachmentUploadCommand('0123456789abcdef0123456789abcdef', r'../../$(touch injected);"file.png');
    expect(command, isNot(contains(r'$(')));
    expect(command, isNot(contains('../')));
    expect(command, contains('umask 077'));
    expect(command, contains('mkdir "\$HOME/'));
    expect(() => attachmentUploadCommand('../bad', 'file'), throwsArgumentError);
  });

  test('attachment-only message and queued steer preserve image paths', () {
    final text = attachmentPrompt('', const [RemoteAttachment(path: '/remote/photo.png', isImage: true)]);
    expect(text, contains('/remote/photo.png'));
    final queue = TaskMessageQueue<QueuedTaskMessage>();
    queue.enqueue('thread', QueuedTaskMessage(id: '1', text: text, imagePaths: const ['/remote/photo.png']));
    expect(queue.take('thread')!.imagePaths, ['/remote/photo.png']);
  });
}
