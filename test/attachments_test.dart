import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:android_ssh_codex/src/attachments.dart';
import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/tasks/message_attachments.dart';
import 'package:android_ssh_codex/src/tasks/task_message_queue.dart';
import 'package:android_ssh_codex/src/transport/attachment_upload.dart';
import 'package:flutter_test/flutter_test.dart';

final class _UploadBuffer {
  final bytes = <int>[];
}

final class _FakeUploadSession implements AttachmentUploadSession {
  _FakeUploadSession(this.buffer,
      {required this.failAfterFirstChunk, required this.offsets});

  final _UploadBuffer buffer;
  final bool failAfterFirstChunk;
  final List<int> offsets;

  @override
  String get path => '/remote/file.bin';

  @override
  Future<int> length() async => buffer.bytes.length;

  @override
  Future<void> write(Stream<Uint8List> bytes, int offset,
      {void Function(int acknowledged)? onProgress}) async {
    offsets.add(offset);
    var written = 0;
    await for (final chunk in bytes) {
      final accepted = failAfterFirstChunk
          ? Uint8List.sublistView(chunk, 0, chunk.length ~/ 2)
          : chunk;
      if (offset == buffer.bytes.length) {
        buffer.bytes.addAll(accepted);
      } else {
        buffer.bytes.replaceRange(offset, offset + accepted.length, accepted);
      }
      offset += accepted.length;
      written += accepted.length;
      onProgress?.call(written);
      if (failAfterFirstChunk) throw TimeoutException('simulated disconnect');
    }
  }

  @override
  Future<void> close() async {}
}

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
    const empty = LocalAttachment(
        name: 'file', path: '/cache/a', size: 0, isImage: false);
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
    expect(
        () => Attachments.validate(List.filled(4, allowed)), returnsNormally);
  });

  test('video MIME overrides an image flag from the picker', () async {
    messenger.setMockMethodCallHandler(
        Attachments.channel,
        (call) async => {
              'name': 'clip',
              'path': '/cache/picked.bin',
              'size': 3,
              'isImage': true,
              'mimeType': 'video/mp4',
            });
    final video = (await Attachments.pick(image: false))!;
    expect(video.isImage, isFalse);
    expect(video.isVideo, isTrue);
    expect(video.mimeType, 'video/mp4');
  });

  test('video filenames never become native image inputs', () {
    const video = RemoteAttachment(path: '/remote/clip.MP4', isImage: true);
    expect(video.isImage, isFalse);
    expect(video.isVideo, isTrue);
    final prompt = attachmentPrompt('Inspect', [video]);
    expect(prompt, contains('Video file (video/mp4):\n/remote/clip.MP4'));
  });

  test('long upload names retain the media extension', () {
    final command = attachmentUploadCommand(
        '0123456789abcdef0123456789abcdef', '${'a' * 160}.mp4');
    expect(command, contains('.mp4'));
  });

  test('video MIME is normalized and cannot inject prompt metadata', () {
    const video = RemoteAttachment(
        path: '/remote/clip',
        isImage: true,
        mimeType: 'Video/MP4; codecs=avc1');
    final parsed = parseAttachmentMessage(attachmentPrompt('', [video]));
    expect(parsed.text, isEmpty);
    expect(parsed.attachments.single.isVideo, isTrue);
    expect(parsed.attachments.single.isImage, isFalse);
    const invalid = RemoteAttachment(
        path: '/remote/clip', isImage: false, mimeType: 'video/mp4\ninjected');
    expect(attachmentPrompt('', [invalid]), isNot(contains('injected')));
  });

  test('source-code extensions are not mistaken for videos', () {
    for (final path in ['/remote/index.ts', '/remote/module.mts']) {
      final file = RemoteAttachment(path: path, isImage: false);
      expect(file.isVideo, isFalse);
    }
  });

  test('remote upload command never interpolates shell syntax from filename',
      () {
    final command = attachmentUploadCommand('0123456789abcdef0123456789abcdef',
        r'../../$(touch injected);"file.png');
    expect(command, isNot(contains(r'$(')));
    expect(command, isNot(contains('../')));
    expect(command, contains(r'umask\ 077'));
    expect(command, startsWith('/bin/sh -c '));
    expect(command, contains(r'touch\ '));
    expect(
        () => attachmentUploadCommand('../bad', 'file'), throwsArgumentError);
  });

  test('attachment upload source streams from disk and detects changes',
      () async {
    final directory = await Directory.systemTemp.createTemp('attachment-test-');
    final file = File('${directory.path}/payload');
    addTearDown(() => directory.delete(recursive: true));
    await file.writeAsBytes(List.generate(200000, (index) => index % 251));
    final chunks =
        await attachmentFileStream(file, expectedSize: 200000).toList();
    expect(chunks.length, greaterThan(1));
    expect(chunks.fold<int>(0, (sum, chunk) => sum + chunk.length), 200000);
    await expectLater(
        attachmentFileStream(file, expectedSize: 200001).drain<void>(),
        throwsStateError);
  });

  test('resumable upload continues from the acknowledged remote offset',
      () async {
    final directory = await Directory.systemTemp.createTemp('upload-resume-');
    final file = File('${directory.path}/payload');
    addTearDown(() => directory.delete(recursive: true));
    final contents = List.generate(200000, (index) => index % 251);
    await file.writeAsBytes(contents);
    final attachment = LocalAttachment(
        name: 'payload.mp4',
        path: file.path,
        size: contents.length,
        isImage: false,
        mimeType: 'video/mp4');
    final buffer = _UploadBuffer();
    final offsets = <int>[];
    var connections = 0;
    final remote = await uploadAttachmentResumable(
      attachment: attachment,
      target: AttachmentUploadTarget.forAttachment(attachment),
      cancellation: AttachmentUploadCancellation(),
      retryDelay: Duration.zero,
      connect: () async => _FakeUploadSession(buffer,
          failAfterFirstChunk: ++connections == 1, offsets: offsets),
    );
    expect(connections, 2);
    expect(offsets.first, 0);
    expect(offsets.last, greaterThan(0));
    expect(buffer.bytes, contents);
    expect(remote.path, '/remote/file.bin');
    expect(remote.isVideo, isTrue);
    expect(remote.isImage, isFalse);
    expect(remote.mimeType, 'video/mp4');
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
