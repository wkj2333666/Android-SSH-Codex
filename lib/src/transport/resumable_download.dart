import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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
    final listeners = _waiters.toList();
    _waiters.clear();
    for (final waiter in listeners) {
      waiter();
    }
  }

  void check() {
    if (isCancelled) throw DownloadCancelled();
  }

  void Function() onCancel(void Function() listener) {
    if (isCancelled) {
      listener();
    } else {
      _waiters.add(listener);
    }
    return () => _waiters.remove(listener);
  }

  Future<T> wait<T>(Future<T> future) async {
    final signal = Completer<T>();
    final result = Future.any([future, signal.future]);
    final unsubscribe = onCancel(() => signal.completeError(DownloadCancelled()));
    try {
      return await result;
    } finally {
      unsubscribe();
    }
  }
}

class DownloadMetadata {
  const DownloadMetadata(this.size, this.modifiedAt);
  final int size;
  final int? modifiedAt;

  bool canResumeWith(DownloadMetadata other) =>
      modifiedAt != null && modifiedAt == other.modifiedAt && size == other.size;

  bool changedFrom(DownloadMetadata other) =>
      size != other.size ||
      (modifiedAt != null &&
          other.modifiedAt != null &&
          modifiedAt != other.modifiedAt);
}

abstract class DownloadSource {
  Future<DownloadMetadata> metadata();
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
  SftpDownloadSource._(this.connection, this.sftp, this.file, this.maxBytes) {
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
  final int maxBytes;
  bool _closed = false;
  bool _sftpClosed = false;

  static Future<SftpDownloadSource> open(SshConnection connection, String path,
      {int maxBytes = maxDownloadBytes}) async {
    SftpClient? sftp;
    try {
      validateRemoteFilePath(path);
      sftp =
          await connection.client.sftp().timeout(const Duration(seconds: 15));
      final file = await _untilClosed(connection.client, sftp.open(path))
          .timeout(const Duration(seconds: 15));
      return SftpDownloadSource._(connection, sftp, file, maxBytes);
    } catch (_) {
      sftp?.close();
      await connection.close(reason: 'download_open_failed');
      rethrow;
    }
  }

  @override
  Future<DownloadMetadata> metadata() async {
    if (connection.client.isClosed) {
      throw SSHStateError('Download connection closed');
    }
    final attrs = await _untilClosed(connection.client, file.stat());
    final size = attrs.size;
    if (!attrs.isFile || size == null || size < 0 || size > maxBytes) {
      throw FileDownloadException('Download requires a regular file of at most '
          '${maxBytes == maxDownloadBytes ? '1 GiB' : '${maxBytes ~/ 1048576} MiB'}.');
    }
    return DownloadMetadata(size, attrs.modifyTime);
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
/// A retry resumes only from successfully written bytes and only when size and
/// modification time match. Metadata is not a content fingerprint.
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
  DownloadMetadata? previous;
  var retries = 0;
  var stage = 'connect';
  final updates = Stopwatch()..start();
  final speed = Stopwatch()..start();
  var speedStart = 0;
  // Reuse the batch for every disk write instead of allocating one buffer
  // per 256 KiB. It is only reused once the write completes.
  final writeBatch = Uint8List(_writeBatchBytes);
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
        stage = 'stat';
        onProgress
            ?.call(DownloadProgress(received, previous?.size, checking: true));
        final remote = await cancellation
            .wait(activeSource.metadata())
            .timeout(operationTimeout);
        if (remote.size < 0 || remote.size > maxDownloadBytes) {
          throw const FileDownloadException(
              'File exceeds the 1 GiB download limit.');
        }
        if (received > 0 && previous?.canResumeWith(remote) != true) {
          // An altered or unidentifiable source must never be appended to the
          // partial file, even if it has the same length.
          stage = 'write';
          await output.truncate(0);
          await output.setPosition(0);
          received = 0;
        }
        previous = remote;
        onProgress?.call(DownloadProgress(received, remote.size));
        speedStart = received;
        speed.reset();
        final pending = Queue<(int, Future<_ReadResult>)>();
        var batchLength = 0;
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
          writeBatch.setRange(batchLength, batchLength + length, block);
          batchLength += length;
          prefetch();
          if (batchLength == _writeBatchBytes || pending.isEmpty) {
            cancellation.check();
            stage = 'write';
            await output.writeFrom(writeBatch, 0, batchLength);
            received += batchLength;
            batchLength = 0;
            if (updates.elapsedMilliseconds >= 100 ||
                received == remote.size) {
              onProgress?.call(DownloadProgress(received, remote.size,
                  bytesPerSecond: (received - speedStart) *
                      1000000 /
                      max(1, speed.elapsedMicroseconds)));
              updates.reset();
            }
          }
        }
        stage = 'stat';
        onProgress
            ?.call(DownloadProgress(received, remote.size, checking: true));
        final ending = await cancellation
            .wait(activeSource.metadata())
            .timeout(operationTimeout);
        if (received != remote.size || ending.changedFrom(remote)) {
          throw const FileDownloadException(
              'Remote file changed during download. Retry from the beginning.');
        }
        stage = 'write';
        await output.flush();
        cancellation.check();
        onProgress?.call(DownloadProgress(received, remote.size));
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
          DownloadProgress(received, previous?.size, reconnecting: true));
      await cancellation.wait(Future<void>.delayed(retryDelay * retries));
    }
  } finally {
    await output.close();
  }
}
