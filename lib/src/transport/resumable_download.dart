import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';

import 'file_download.dart';
import 'ssh_connector.dart';

class DownloadCancelled implements Exception {
  @override
  String toString() => 'Download cancelled';
}

class DownloadCancellation {
  final _waiters = <void Function()>{};
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  void cancel() {
    if (isCancelled) return;
    _cancelled = true;
    for (final waiter in _waiters) {
      waiter();
    }
    _waiters.clear();
  }

  void check() {
    if (isCancelled) throw DownloadCancelled();
  }

  Future<T> wait<T>(Future<T> future) async {
    final signal = Completer<T>();
    void wake() => signal.completeError(DownloadCancelled());
    final result = Future.any([future, signal.future]);
    if (isCancelled) {
      wake();
    } else {
      _waiters.add(wake);
    }
    try {
      return await result;
    } finally {
      _waiters.remove(wake);
    }
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

Future<T> _untilClosed<T>(SSHClient client, Future<T> operation) => Future.any([
      operation,
      client.done
          .then<T>((_) => throw SSHStateError('Download connection closed')),
    ]);

/// Owns its entire SSH connection. dartssh2 2.x SftpClient.close alone does not
/// release its SSH channel, so a download must never borrow the chat client.
class SftpDownloadSource implements DownloadSource {
  SftpDownloadSource._(
      this.connection, this.sftp, this.file, this.path, this.maxBytes) {
    // dartssh2 may leave SFTP replies pending after the transport disappears.
    // Release them once per connection, not with a close listener per read.
    unawaited(connection.client.done.then<void>(
      (_) => _closeSftp(),
      onError: (Object _, StackTrace __) => _closeSftp(),
    ));
  }
  final SshConnection connection;
  final SftpClient sftp;
  final SftpFile file;
  final String path;
  final int maxBytes;
  bool _closed = false;
  bool _sftpClosed = false;

  static Future<SftpDownloadSource> open(SshConnection connection, String path,
      {int maxBytes = maxDownloadBytes}) async {
    SftpClient? sftp;
    try {
      fileDownloadCommand(path); // Reject malformed paths before any remote IO.
      sftp =
          await connection.client.sftp().timeout(const Duration(seconds: 15));
      final file = await _untilClosed(connection.client, sftp.open(path))
          .timeout(const Duration(seconds: 15));
      return SftpDownloadSource._(connection, sftp, file, path, maxBytes);
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
    final attrs = await _untilClosed(connection.client, file.stat());
    final size = attrs.size;
    if (!attrs.isFile || size == null || size < 0 || size > maxBytes) {
      throw FileDownloadException('Download requires a regular file of at most '
          '${maxBytes == maxDownloadBytes ? '1 GiB' : '${maxBytes ~/ 1048576} MiB'}.');
    }
    final result = await _untilClosed(connection.client,
        connection.client.runWithResult(fileDownloadDigestCommand(path)));
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
    BytesBuilder? buffer;
    var remaining = length;
    while (remaining > 0) {
      if (_sftpClosed || connection.client.isClosed) {
        throw SSHStateError('Download connection closed');
      }
      // Keep only one wire request per read future: on socket loss there
      // are no internal, unobserved SFTP futures left over.
      final wanted = min(remaining, resumableReadBytes);
      final bytes = await file
          .read(
            offset: offset,
            length: wanted,
            chunkSize: wanted,
            maxPendingRequests: 1,
          )
          .fold<Uint8List?>(null, (_, data) => data);
      if (bytes == null) break;
      if (bytes.length == length) return bytes;
      // Some SFTP servers return fewer bytes than requested without EOF.
      (buffer ??= BytesBuilder(copy: false)).add(bytes);
      offset += bytes.length;
      remaining -= bytes.length;
    }
    return buffer?.takeBytes() ?? Uint8List(0);
  }

  void _closeSftp() {
    if (_sftpClosed) return;
    _sftpClosed = true;
    sftp.close();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _closeSftp();
    } finally {
      await connection.close(reason: 'download_connection_closed');
    }
  }
}

const resumableReadBytes = 32 * 1024;
const resumableReadWindow = 256;
const _writeBatchBytes = 256 * 1024;

typedef _ReadResult = List<int> Function();

Future<_ReadResult> _prefetch(DownloadSource source, int offset, int length) =>
    Future.sync(() => source.read(offset, length)).then<_ReadResult>(
      (bytes) => () => bytes,
      // A later offset can fail even while we are writing an earlier one.
      // Observe that error immediately, then rethrow in file order.
      onError: (Object error, StackTrace stack) =>
          () => Error.throwWithStackTrace(error, stack),
    );

/// Slide the window as each ordered read completes instead of stopping at
/// batch boundaries. At most 8 MiB of reads plus one disk batch is buffered.
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
  Duration verificationTimeout = const Duration(minutes: 30),
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
        final activeSource =
            await cancellation.wait(opening).timeout(operationTimeout);
        source = activeSource;
        stage = 'identify';
        onProgress
            ?.call(DownloadProgress(received, identity?.size, verifying: true));
        final remote = await cancellation
            .wait(activeSource.identify())
            .timeout(verificationTimeout);
        if (remote.size < 0 || remote.size > maxDownloadBytes) {
          throw const FileDownloadException(
              'File exceeds the 1 GiB download limit.');
        }
        if (identity != null && !identity.matches(remote)) {
          throw const FileDownloadException(
              'Remote file changed. Retry the download from the beginning.');
        }
        identity ??= remote;
        speedStart = received;
        speed.reset();
        final pending = Queue<(int, Future<_ReadResult>)>();
        final writeBatch = BytesBuilder(copy: false);
        var offset = received;
        void prefetch() {
          while (pending.length < resumableReadWindow && offset < remote.size) {
            final length = min(resumableReadBytes, remote.size - offset);
            pending.add((length, _prefetch(activeSource, offset, length)));
            offset += length;
          }
        }

        stage = 'read';
        prefetch();
        while (pending.isNotEmpty) {
          cancellation.check();
          stage = 'read';
          final (length, read) = pending.removeFirst();
          final block =
              (await cancellation.wait(read.timeout(operationTimeout)))();
          if (block.length != length) {
            throw const FileDownloadException(
                'Remote file was truncated during download.');
          }
          writeBatch.add(block);
          prefetch();
          if (writeBatch.length >= _writeBatchBytes || pending.isEmpty) {
            cancellation.check();
            stage = 'write';
            final bytes = writeBatch.takeBytes();
            await output.writeFrom(bytes);
            received += bytes.length;
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
            .wait(activeSource.identify())
            .timeout(verificationTimeout);
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
