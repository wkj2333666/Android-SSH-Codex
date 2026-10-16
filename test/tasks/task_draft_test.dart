import 'dart:async';
import 'dart:io';

import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/attachments.dart';
import 'package:android_ssh_codex/src/profiles/host_profile.dart';
import 'package:android_ssh_codex/src/tasks/task_draft.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('upload continues without page listeners and can finish offscreen', () async {
    final done = Completer<RemoteAttachment>();
    final draft = TaskDraft(upload: (file, target, cancel, {onProgress}) => done.future);
    final dir = await Directory.systemTemp.createTemp('task-draft-');
    final file = File('${dir.path}/upload.txt');
    await file.writeAsString('draft');
    final local = LocalAttachment(name: 'upload.txt', path: file.path, size: 5, isImage: false);
    void listener() {}
    draft.addListener(listener);
    draft.composer.text = 'saved text';
    draft.addAttachment(local);
    final transfer = draft.attachments.single;
    draft.removeListener(listener); // task page was disposed
    expect(transfer.cancellation.isCancelled, isFalse);
    expect(await file.exists(), isTrue);
    done.complete(const RemoteAttachment(path: '/remote/upload.txt', isImage: false));
    await Future<void>.delayed(Duration.zero);
    expect(draft.attachments.single.ready, isTrue);
    expect(draft.composer.text, 'saved text');
    draft.removeAttachment(transfer);
    expect(draft.attachments, isEmpty);
    draft.dispose();
    await Future<void>.delayed(Duration.zero);
    await dir.delete(recursive: true);
  });

  test('failed transfer retries with the same resumable target', () async {
    final targets = <Object>[];
    var calls = 0;
    final draft = TaskDraft(upload: (file, target, cancel, {onProgress}) async {
      targets.add(target);
      if (calls++ == 0) throw StateError('offline');
      return const RemoteAttachment(path: '/remote/file', isImage: false);
    });
    draft.addAttachment(const LocalAttachment(
      name: 'file', path: '/nonexistent/draft-fixture', size: 1, isImage: false));
    await Future<void>.delayed(Duration.zero);
    expect(draft.attachments.single.state, AttachmentState.failed);
    await draft.upload(draft.attachments.single);
    expect(identical(targets.first, targets.last), isTrue);
    expect(draft.attachments.single.ready, isTrue);
    draft.dispose();
  });

  test('removing an active upload cancels it and ignores late completion', () async {
    final done = Completer<RemoteAttachment>();
    final draft = TaskDraft(upload: (file, target, cancel, {onProgress}) => done.future);
    draft.addAttachment(const LocalAttachment(
      name: 'file', path: '/nonexistent/draft-fixture', size: 1, isImage: false));
    final transfer = draft.attachments.single;
    draft.removeAttachment(transfer);
    expect(transfer.cancellation.isCancelled, isTrue);
    done.complete(const RemoteAttachment(path: '/remote/file', isImage: false));
    await Future<void>.delayed(Duration.zero);
    expect(draft.attachments, isEmpty);
    expect(transfer.remote, isNull);
    draft.dispose();
  });

  test('draft keys separate hosts as well as tasks', () async {
    final controller = AppController.memory();
    Future<void> selectHost(String id) => controller.saveProfile(
      HostProfile(id: id, label: id, hostName: '$id.example', user: 'codex', port: 22),
      const HostSecret(password: 'test'),
    );
    await selectHost('a');
    final first = controller.draftForTask('same-thread');
    first.composer.text = 'host a';
    expect(controller.draftForTask('other-thread').composer.text, isEmpty);
    await selectHost('b');
    expect(controller.draftForTask('same-thread').composer.text, isEmpty);
    await selectHost('a');
    expect(identical(controller.draftForTask('same-thread'), first), isTrue);
    controller.dispose();
  });
}
