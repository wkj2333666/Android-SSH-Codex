import 'dart:async';

import 'package:flutter/widgets.dart';

import '../attachments.dart';
import '../protocol/codex_remote_api.dart';
import '../transport/attachment_upload.dart';
import 'task_message_queue.dart';
import 'turn_settings.dart';

typedef DraftUploader = Future<RemoteAttachment> Function(
  LocalAttachment attachment,
  AttachmentUploadTarget target,
  AttachmentUploadCancellation cancellation, {
  void Function(int acknowledged, int total)? onProgress,
});

enum AttachmentState { waiting, uploading, uploaded, failed }

final class AttachmentTransfer extends ChangeNotifier {
  AttachmentTransfer(this.local, {AttachmentUploadTarget? target})
      : target = target ?? AttachmentUploadTarget.forAttachment(local);

  final LocalAttachment local;
  final AttachmentUploadTarget target;
  AttachmentUploadCancellation cancellation = AttachmentUploadCancellation();
  AttachmentState state = AttachmentState.uploading;
  RemoteAttachment? remote;
  double progress = 0;
  bool active = false;
  bool discarded = false;
  bool get ready => state == AttachmentState.uploaded && remote != null;

  void updateProgress(double value) {
    if (discarded || value == progress) return;
    progress = value;
    notifyListeners();
  }
}

/// Owned by the application, not by a task page. Navigating away must not
/// cancel a transfer, dispose its editor, or lose an in-flight send's rollback.
final class TaskDraft extends ChangeNotifier {
  TaskDraft({required DraftUploader upload, bool Function()? canUpload,
    this.retainFilesOnDispose = false})
      : _upload = upload,
        _canUpload = canUpload ?? (() => true);

  final DraftUploader _upload;
  final bool Function() _canUpload;
  final bool retainFilesOnDispose;
  final composer = TextEditingController();
  List<AttachmentTransfer> attachments = [];
  RemoteSkill? skill;
  TurnSettings settings = const TurnSettings();
  TaskSendMode sendMode = TaskSendMode.auto;
  bool sending = false;
  bool picking = false;
  bool _disposed = false;
  bool get disposed => _disposed;

  Map<String, dynamic> toJson() => {
    'text': composer.text,
    'model': settings.model,
    'effort': settings.effort,
    'serviceTier': settings.serviceTier,
    'sendMode': sendMode.name,
    if (skill case final selected?) 'skill': {
      'name': selected.name, 'description': selected.description,
      'path': selected.path,
    },
    'attachments': [for (final file in attachments) {
      'name': file.local.name, 'path': file.local.path,
      'size': file.local.size, 'isImage': file.local.isImage,
      'token': file.target.token, 'remotePath': file.remote?.path,
    }],
  };

  void restore(Map<String, dynamic> value) {
    composer.text = value['text'] as String? ?? '';
    settings = TurnSettings(model: value['model'] as String?,
        effort: value['effort'] as String?,
        serviceTier: value['serviceTier'] as String? ?? 'default');
    sendMode = TaskSendMode.values.firstWhere(
        (mode) => mode.name == value['sendMode'], orElse: () => TaskSendMode.auto);
    if (value['skill'] case final Map saved) {
      skill = RemoteSkill(name: saved['name'] as String,
          description: saved['description'] as String, path: saved['path'] as String);
    }
    for (final raw in value['attachments'] as List? ?? const []) {
      final file = raw as Map;
      final local = LocalAttachment(name: file['name'] as String,
          path: file['path'] as String, size: file['size'] as int,
          isImage: file['isImage'] == true);
      final transfer = AttachmentTransfer(local,
          target: AttachmentUploadTarget.restore(file['token'] as String, local.name));
      final remote = file['remotePath'] as String?;
      if (remote != null) {
        transfer.remote = RemoteAttachment(path: remote, isImage: local.isImage);
        transfer.state = AttachmentState.uploaded;
        transfer.progress = 1;
      } else {
        transfer.state = AttachmentState.waiting;
      }
      attachments.add(transfer);
    }
  }

  void changed() {
    if (!_disposed) notifyListeners();
  }

  void addAttachment(LocalAttachment local) {
    if (_disposed) {
      unawaited(Attachments.release(local));
      return;
    }
    Attachments.validate([...attachments.map((file) => file.local), local]);
    final transfer = AttachmentTransfer(local);
    attachments.add(transfer);
    changed();
    unawaited(upload(transfer));
  }

  Future<void> upload(AttachmentTransfer transfer) async {
    if (_disposed || transfer.active || transfer.discarded) return;
    if (!_canUpload()) {
      transfer.state = AttachmentState.waiting;
      changed();
      return;
    }
    transfer
      ..active = true
      ..cancellation = AttachmentUploadCancellation()
      ..state = AttachmentState.uploading;
    changed();
    final updates = Stopwatch()..start();
    try {
      final remote = await _upload(
        transfer.local,
        transfer.target,
        transfer.cancellation,
        onProgress: (acknowledged, total) {
          if (updates.elapsedMilliseconds < 100 && acknowledged != total) {
            return;
          }
          updates.reset();
          transfer.updateProgress(
              total == 0 ? 1 : (acknowledged / total).clamp(0.0, 1.0));
        },
      );
      if (!transfer.discarded) {
        transfer
          ..remote = remote
          ..progress = 1
          ..state = AttachmentState.uploaded;
      }
    } catch (_) {
      if (!transfer.discarded) {
        transfer.state =
            _canUpload() ? AttachmentState.failed : AttachmentState.waiting;
      }
    } finally {
      transfer.active = false;
      if (transfer.discarded) await Attachments.release(transfer.local);
      changed();
      if (!transfer.discarded &&
          transfer.state == AttachmentState.waiting &&
          _canUpload()) {
        unawaited(upload(transfer));
      }
    }
  }

  void resumeWaitingUploads() {
    if (_disposed || !_canUpload()) return;
    for (final transfer in attachments.toList()) {
      if (transfer.state == AttachmentState.waiting) {
        unawaited(upload(transfer));
      }
    }
  }

  void removeAttachment(AttachmentTransfer transfer) {
    if (transfer.discarded) return;
    transfer
      ..discarded = true
      ..cancellation.cancel();
    attachments.remove(transfer);
    if (!transfer.active) unawaited(Attachments.release(transfer.local));
    changed();
  }

  Future<void> restoreFailedSubmission({
    required String text,
    required List<AttachmentTransfer> files,
    RemoteSkill? submittedSkill,
  }) async {
    if (_disposed) {
      await Attachments.releaseAll(files.map((file) => file.local));
      return;
    }
    attachments = [...files, ...attachments];
    final current = composer.text;
    final restored = current.isEmpty
        ? text
        : text.isEmpty
            ? current
            : '$text\n$current';
    composer.value = TextEditingValue(
      text: restored,
      selection: TextSelection.collapsed(offset: restored.length),
    );
    skill ??= submittedSkill;
    changed();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final transfer in attachments.toList()) {
      if (retainFilesOnDispose) {
        transfer.cancellation.cancel();
      } else {
        removeAttachment(transfer);
      }
    }
    composer.dispose();
    super.dispose();
  }
}
