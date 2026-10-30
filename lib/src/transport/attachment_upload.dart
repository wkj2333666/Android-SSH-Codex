import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../attachments.dart';
import 'ssh_connector.dart';

/// Bounded image reads for lazily mounted timeline thumbnails and previews.
Future<Uint8List> readAttachmentImage(SSHClient client, String path) async {
  if (!path.startsWith('/') || path.contains('\u0000')) {
    throw ArgumentError('Expected a remote absolute path');
  }
  final quoted = "'${path.replaceAll("'", "'\\''")}'";
  var timedOut = false;
  final opening = client
      .execute(
          'test -f $quoted && head -c ${Attachments.maxImagePreviewBytes + 1} -- $quoted')
      .then((session) {
    if (timedOut) session.close();
    return session;
  });
  final session =
      await opening.timeout(const Duration(seconds: 15), onTimeout: () {
    timedOut = true;
    throw TimeoutException('Image channel timed out');
  });
  final bytes = BytesBuilder(copy: false);
  final stderr = session.stderr.listen((_) {}, onError: (Object _) {});
  try {
    await (() async {
      await session.stdin.close();
      await for (final chunk in session.stdout) {
        if (bytes.length + chunk.length > Attachments.maxImagePreviewBytes) {
          throw StateError('Image exceeds 10 MiB');
        }
        bytes.add(chunk);
      }
      await session.done;
      if (session.exitCode != 0) throw StateError('Image unavailable');
    })()
        .timeout(const Duration(seconds: 20));
    return bytes.takeBytes();
  } finally {
    session.close();
    await stderr.cancel();
  }
}

String attachmentUploadCommand(String token, String name) {
  if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(token)) {
    throw ArgumentError('Invalid attachment token');
  }
  final safeName = name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  final dot = safeName.lastIndexOf('.');
  final extension = dot > 0 && safeName.length - dot <= 12
      ? safeName.substring(dot)
      : '';
  final fileName = safeName.isEmpty
      ? 'attachment'
      : safeName.length <= 100
          ? safeName
          : '${safeName.substring(0, 100 - extension.length)}$extension';
  const relative = '.local/share/android-ssh-codex/attachments';
  final script = 'umask 077; '
      'base="\$HOME/$relative"; dir="\$base/$token"; '
      'file="\$dir/file-$fileName"; '
      'mkdir -p "\$base" "\$dir" && touch "\$file" || exit 1; '
      'printf "%s" "\$file"';
  final argument = script.replaceAllMapped(
      RegExp(r'[^a-zA-Z0-9_./-]'), (match) => '\\${match[0]}');
  return '/bin/sh -c $argument';
}

final class AttachmentUploadTarget {
  AttachmentUploadTarget._(this.token, this.name);

  factory AttachmentUploadTarget.restore(String token, String name) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(token)) {
      throw ArgumentError('Invalid saved attachment token');
    }
    return AttachmentUploadTarget._(token, name);
  }

  factory AttachmentUploadTarget.forAttachment(LocalAttachment attachment) {
    final random = Random.secure();
    final token = List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    return AttachmentUploadTarget._(token, attachment.name);
  }

  final String token;
  final String name;
}

final class AttachmentUploadCancellation {
  final _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw const AttachmentUploadCancelled();
  }

  Future<T> wait<T>(Future<T> future) => Future.any([
        future,
        _cancelled.future
            .then<T>((_) => throw const AttachmentUploadCancelled()),
      ]);
}

final class AttachmentUploadCancelled implements Exception {
  const AttachmentUploadCancelled();

  @override
  String toString() => 'Attachment upload cancelled';
}

abstract interface class AttachmentUploadSession {
  String get path;
  Future<int> length();
  Future<void> write(Stream<Uint8List> bytes, int offset,
      {void Function(int acknowledged)? onProgress});
  Future<void> close();
}

final class SftpAttachmentUploadSession implements AttachmentUploadSession {
  SftpAttachmentUploadSession._(
      this.connection, this.sftp, this.file, this.path);

  final SshConnection connection;
  final SftpClient sftp;
  final SftpFile file;

  @override
  final String path;

  static Future<SftpAttachmentUploadSession> open(
      SshConnection connection, AttachmentUploadTarget target) async {
    SftpClient? sftp;
    SftpFile? file;
    try {
      final result = await _untilUploadConnectionCloses(
          connection.client,
          connection.client.runWithResult(
              attachmentUploadCommand(target.token, target.name)));
      final path = utf8.decode(result.stdout);
      if (result.exitCode != 0 ||
          !path.startsWith('/') ||
          path.contains('\n') ||
          path.contains('\r')) {
        throw StateError('Cannot prepare the remote attachment.');
      }
      final openedSftp = await _untilUploadConnectionCloses(
          connection.client, connection.client.sftp());
      sftp = openedSftp;
      final openedFile = await _untilUploadConnectionCloses(
          connection.client,
          openedSftp.open(path,
              mode: SftpFileOpenMode.create | SftpFileOpenMode.write));
      file = openedFile;
      return SftpAttachmentUploadSession._(
          connection, openedSftp, openedFile, path);
    } catch (_) {
      await file?.close().catchError((_) {});
      sftp?.close();
      await connection.close(reason: 'attachment_upload_open_failed');
      rethrow;
    }
  }

  @override
  Future<int> length() async {
    final size =
        (await _untilUploadConnectionCloses(connection.client, file.stat()))
            .size;
    if (size == null || size < 0) {
      throw StateError('Cannot read remote attachment size.');
    }
    return size;
  }

  @override
  Future<void> write(Stream<Uint8List> bytes, int offset,
      {void Function(int acknowledged)? onProgress}) async {
    var acknowledged = 0;
    await for (final chunk in bytes) {
      await _untilUploadConnectionCloses(
          connection.client, file.writeBytes(chunk, offset: offset));
      offset += chunk.length;
      acknowledged += chunk.length;
      onProgress?.call(acknowledged);
    }
  }

  @override
  Future<void> close() async {
    try {
      await file.close().catchError((_) {});
      sftp.close();
    } finally {
      await connection.close(reason: 'attachment_upload_connection_closed');
    }
  }
}

Future<T> _untilUploadConnectionCloses<T>(
        SSHClient client, Future<T> operation) =>
    Future.any([
      operation,
      client.done.then<T>(
          (_) => throw SSHStateError('Attachment upload connection closed')),
    ]);

bool _retryableUploadError(Object error) {
  if (error is SSHAuthAbortError) {
    final reason = error.reason;
    return reason != null && _retryableUploadError(reason);
  }
  return error is TimeoutException ||
      error is SocketException ||
      error is SSHSocketError ||
      error is SSHStateError ||
      error is SftpAbortError ||
      (error is SSHHandshakeError && error.message == 'Handshake timed out');
}

Future<RemoteAttachment> uploadAttachmentResumable({
  required LocalAttachment attachment,
  required AttachmentUploadTarget target,
  required Future<AttachmentUploadSession> Function() connect,
  required AttachmentUploadCancellation cancellation,
  void Function(int acknowledged, int total)? onProgress,
  void Function(int attempt, int acknowledged, Object error)? onRetry,
  int maxRetries = 8,
  Duration operationTimeout = const Duration(seconds: 30),
  Duration retryDelay = const Duration(seconds: 1),
}) async {
  Attachments.validate([attachment]);
  final source = File(attachment.path);
  final actualSize = await source.length();
  if (actualSize != attachment.size || actualSize > Attachments.maxFileBytes) {
    throw StateError('Selected attachment changed before upload.');
  }
  var retries = 0;
  var acknowledged = 0;
  while (true) {
    cancellation.check();
    AttachmentUploadSession? session;
    var openingExpired = false;
    try {
      final opening = connect().then((value) async {
        if (openingExpired || cancellation.isCancelled) await value.close();
        return value;
      });
      session = await cancellation.wait(opening).timeout(operationTimeout);
      acknowledged =
          await cancellation.wait(session.length()).timeout(operationTimeout);
      if (acknowledged > attachment.size) {
        throw StateError('Remote attachment is larger than the selected file.');
      }
      onProgress?.call(acknowledged, attachment.size);
      if (acknowledged < attachment.size) {
        final resumeOffset = acknowledged;
        final stream = attachmentFileStream(source,
            expectedSize: attachment.size, offset: resumeOffset);
        await cancellation
            .wait(session.write(stream, resumeOffset, onProgress: (written) {
          onProgress?.call(resumeOffset + written, attachment.size);
        }));
      }
      acknowledged =
          await cancellation.wait(session.length()).timeout(operationTimeout);
      if (acknowledged != attachment.size) {
        throw SSHStateError('Attachment upload was incomplete');
      }
      onProgress?.call(acknowledged, attachment.size);
      return RemoteAttachment(
          path: session.path,
          isImage: attachment.isImage,
          mimeType: attachment.videoMimeType ?? attachment.mimeType);
    } catch (error) {
      openingExpired = true;
      if (error is AttachmentUploadCancelled || cancellation.isCancelled) {
        throw const AttachmentUploadCancelled();
      }
      if (!_retryableUploadError(error) || retries >= maxRetries) rethrow;
      onRetry?.call(++retries, acknowledged, error);
    } finally {
      openingExpired = true;
      await session?.close();
    }
    await cancellation
        .wait(Future<void>.delayed(retryDelay * min(retries, 10)));
  }
}

/// Reads an attachment with disk backpressure and validates that it did not
/// change after selection. At most one file-system chunk is held by this layer.
Stream<Uint8List> attachmentFileStream(File source,
    {required int expectedSize, int offset = 0}) async* {
  if (offset < 0 || offset > expectedSize) {
    throw ArgumentError.value(offset, 'offset');
  }
  var sent = offset;
  await for (final chunk in source.openRead(offset, expectedSize)) {
    sent += chunk.length;
    if (sent > Attachments.maxFileBytes || sent > expectedSize) {
      throw StateError('Selected attachment changed during upload.');
    }
    yield chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
  }
  if (sent != expectedSize) {
    throw StateError('Selected attachment changed during upload.');
  }
}
