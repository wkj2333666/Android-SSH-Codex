import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';

import 'file_download.dart';
import 'ssh_connector.dart';

class DownloadCancelled implements Exception {
  @override
  String toString() => 'Download cancelled';
}

class DownloadCancellation {
  final _done = Completer<void>();
  bool get isCancelled => _done.isCompleted;
  void cancel() {
    if (!isCancelled) _done.complete();
  }

  void check() {
    if (isCancelled) throw DownloadCancelled();
  }

  Future<T> wait<T>(Future<T> future) {
    return Future.any<T>(
        [future, _done.future.then<T>((_) => throw DownloadCancelled())]);
  }
}

class DownloadIdentity {
  const DownloadIdentity(this.size, this.digest);
  final int size;
  final String digest;
  bool matches(DownloadIdentity other) =>
      size == other.size && digest == other.digest;
}

abstract class DownloadSource {
  Future<DownloadIdentity> identify();
  Future<List<int>> read(int offset, int length);
  Future<void> close();
}

bool _retryable(Object error) {
  if (error is SSHAuthAbortError) {
    final cause = error.reason;
    return cause != null && _retryable(cause);
  }
  return error is TimeoutException ||
      error is SocketException ||
      error is SSHSocketError ||
      error is SSHStateError ||
      error is SftpAbortError ||
      (error is SSHHandshakeError && error.message == 'Handshake timed out');
}

/// Owns its entire SSH connection. dartssh2 2.x SftpClient.close alone does not
/// release its SSH channel, so a download must never borrow the chat client.
class SftpDownloadSource implements DownloadSource {
  SftpDownloadSource._(this.connection, this.sftp, this.file, this.path);
  final SshConnection connection;
  final SftpClient sftp;
  final SftpFile file;
  final String path;
  bool _closed = false;

  static Future<SftpDownloadSource> open(
      SshConnection connection, String path) async {
    SftpClient? sftp;
    try {
      fileDownloadCommand(path); // Reject malformed paths before any remote IO.
      sftp = await connection.client.sftp();
      final file = await sftp.open(path).timeout(const Duration(seconds: 15));
      return SftpDownloadSource._(connection, sftp, file, path);
    } catch (_) {
      sftp?.close();
      await connection.close(reason: 'download_open_failed');
      rethrow;
    }
  }

  @override
  Future<DownloadIdentity> identify() async {
    if (connection.client.isClosed) {
      throw SSHStateError('Download connection closed');
    }
    final attrs = await file.stat();
    final size = attrs.size;
    if (!attrs.isFile || size == null || size < 0 || size > maxDownloadBytes) {
      throw const FileDownloadException(
          'Download requires a regular file of at most 100 MiB.');
    }
    final result =
        await connection.client.runWithResult(fileDownloadDigestCommand(path));
    final digest = RegExp(r'^([a-fA-F0-9]{64})\s')
        .firstMatch(String.fromCharCodes(result.stdout))
        ?.group(1);
    if (result.exitCode != 0 || digest == null) {
      throw const FileDownloadException(
          'Cannot verify the remote file (sha256sum is required).');
    }
    return DownloadIdentity(size, digest.toLowerCase());
  }

  @override
  Future<List<int>> read(int offset, int length) async {
    if (connection.client.isClosed) {
      throw SSHStateError('Download connection closed');
    }
    return file.readBytes(offset: offset, length: length);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      sftp.close();
    } finally {
      await connection.close(reason: 'download_connection_closed');
    }
  }
}

/// Four 256 KiB reads in flight, one ordered writer. The SFTP channel's
/// listener stays unpaused while disk writes run; payload buffering <= 1 MiB.
/// A retry resumes only from successfully written bytes and only for identical
/// remote content. No automatic retry of writes or unsafe command submissions.
Future<void> downloadResumableFile({
  required Future<DownloadSource> Function() connect,
  required File destination,
  required DownloadCancellation cancellation,
  void Function(DownloadProgress)? onProgress,
  void Function(int attempt, int received, Object error)? onRetry,
  int maxRetries = 3,
  Duration operationTimeout = const Duration(seconds: 30),
  Duration retryDelay = const Duration(seconds: 1),
}) async {
  final output = await destination.open(mode: FileMode.write);
  var received = 0;
  DownloadIdentity? identity;
  var retries = 0;
  var stage = 'connect';
  final updates = Stopwatch()..start();
  final speed = Stopwatch()..start();
  var speedStart = 0;
  try {
    while (true) {
      cancellation.check();
      DownloadSource? source;
      var openingExpired = false;
      try {
        stage = 'connect';
        final opening = connect().then((value) async {
          if (openingExpired || cancellation.isCancelled) await value.close();
          return value;
        });
        source = await cancellation.wait(opening).timeout(operationTimeout);
        stage = 'identify';
        onProgress
            ?.call(DownloadProgress(received, identity?.size, verifying: true));
        final remote = await cancellation
            .wait(source.identify())
            .timeout(operationTimeout);
        if (remote.size < 0 || remote.size > maxDownloadBytes) {
          throw const FileDownloadException(
              'File exceeds the 100 MiB download limit.');
        }
        if (identity != null && !identity.matches(remote)) {
          throw const FileDownloadException(
              'Remote file changed. Retry the download from the beginning.');
        }
        identity ??= remote;
        speedStart = received;
        speed.reset();
        while (received < identity.size) {
          cancellation.check();
          stage = 'read';
          final lengths = <int>[];
          final pending = <Future<List<int>>>[];
          var offset = received;
          for (var i = 0; i < 4 && offset < identity.size; i++) {
            final length = min(downloadChunkBytes, identity.size - offset);
            lengths.add(length);
            pending.add(source.read(offset, length));
            offset += length;
          }
          final blocks = await cancellation
              .wait(Future.wait(pending, eagerError: true))
              .timeout(operationTimeout);
          for (var i = 0; i < blocks.length; i++) {
            cancellation.check();
            if (blocks[i].length != lengths[i]) {
              throw const FileDownloadException(
                  'Remote file was truncated during download.');
            }
            stage = 'write';
            await output.writeFrom(blocks[i]);
            received += blocks[i].length;
            if (updates.elapsedMilliseconds >= 100 ||
                received == identity.size) {
              onProgress?.call(DownloadProgress(received, identity.size,
                  bytesPerSecond: (received - speedStart) *
                      1000000 /
                      max(1, speed.elapsedMicroseconds)));
              updates.reset();
            }
          }
        }
        stage = 'verify';
        onProgress
            ?.call(DownloadProgress(received, identity.size, verifying: true));
        final finalIdentity = await cancellation
            .wait(source.identify())
            .timeout(operationTimeout);
        if (!identity.matches(finalIdentity)) {
          throw const FileDownloadException(
              'Remote file changed during download.');
        }
        await output.flush();
        final digest =
            await cancellation.wait(sha256.bind(destination.openRead()).first);
        if (digest.toString() != identity.digest) {
          throw const FileDownloadException(
              'Download checksum mismatch. The incomplete file was not saved.');
        }
        cancellation.check();
        onProgress?.call(DownloadProgress(received, identity.size));
        return;
      } catch (error) {
        openingExpired = true;
        if (cancellation.isCancelled || error is DownloadCancelled) {
          throw DownloadCancelled();
        }
        if (!_retryable(error) || stage == 'write' || retries >= maxRetries) {
          throw FileDownloadException(
              'Download failed after $received bytes ($stage): $error',
              received: received,
              stage: stage,
              cause: error);
        }
        onRetry?.call(++retries, received, error);
      } finally {
        openingExpired = true;
        await source?.close();
      }
      onProgress?.call(
          DownloadProgress(received, identity?.size, reconnecting: true));
      await cancellation.wait(Future<void>.delayed(retryDelay * retries));
    }
  } finally {
    await output.close();
  }
}
