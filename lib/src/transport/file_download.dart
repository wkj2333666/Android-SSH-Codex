import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

const maxDownloadBytes = 100 * 1024 * 1024;
const downloadChunkBytes = 256 * 1024;

class DownloadProgress {
  const DownloadProgress(this.received, this.total, {this.saving = false,
    this.reconnecting = false, this.verifying = false, this.bytesPerSecond});
  final int received;
  final int? total;
  final bool saving;
  final bool reconnecting;
  final bool verifying;
  final double? bytesPerSecond;
}

class FileDownloadException implements Exception {
  const FileDownloadException(this.message,
      {this.cause, this.received = 0, this.stage, this.exitCode});
  final String message;
  final Object? cause;
  final int received;
  final String? stage;
  final int? exitCode;
  @override
  String toString() => message;
}

String? remoteFilePath(String value, String cwd) {
  try {
    final uri = Uri.parse(value);
    if (uri.hasAuthority && !(uri.scheme == 'file' && uri.host.isEmpty)) {
      return null;
    }
    if (uri.scheme.isNotEmpty &&
        uri.scheme != 'file' &&
        uri.scheme != 'sandbox') {
      return null;
    }
    var path =
        '${uri.path.startsWith('/') ? '/' : ''}${uri.pathSegments.join('/')}';
    if (path.isEmpty ||
        path.contains('\u0000') ||
        path.contains('\n') ||
        path.contains('\r')) {
      return null;
    }
    // Desktop source links sometimes include a line suffix.
    path = path.replaceFirst(RegExp(r':\d+(?::\d+)?$'), '');
    if (!path.startsWith('/')) {
      if (uri.scheme.isNotEmpty || !cwd.startsWith('/')) return null;
      path =
          '/${Uri(path: '$cwd/').resolveUri(Uri(path: path)).pathSegments.join('/')}';
    }
    return path;
  } on FormatException {
    return null;
  }
}

String fileDownloadCommand(String path, {int? offset}) {
  if (!path.startsWith('/') ||
      path.contains('\u0000') ||
      path.contains('\n') ||
      path.contains('\r')) {
    throw ArgumentError('Invalid path');
  }
  final quoted = _shellQuote(path);
  if (offset != null && (offset < 0 || offset % downloadChunkBytes != 0)) {
    throw ArgumentError('Invalid download offset');
  }
  final read = offset == null
      ? 'head -c ${maxDownloadBytes + 1} -- $quoted'
      : 'dd if=$quoted bs=65536 skip=${offset ~/ 65536} count=4 status=none';
  final script = 'if ! test -e $quoted; then exit 44; '
      'elif ! test -f $quoted; then exit 45; '
      'elif ! test -r $quoted; then exit 46; fi; $read';
  // SSH exec uses the account's login shell, which may be fish rather than sh.
  return _posixShellCommand(script);
}

String _posixShellCommand(String script) {
  final argument = script.replaceAllMapped(
      RegExp(r'[^a-zA-Z0-9_./-]'), (match) => '\\${match[0]}');
  return '/bin/sh -c $argument';
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

// The bounded producer is shell-isolated; the outer pipeline works with fish
// and POSIX login shells alike. SFTP metadata and final digest detect changes.
String fileDownloadDigestCommand(String path) =>
    '${fileDownloadCommand(path)} | sha256sum';

Future<void> downloadRemoteFile(SSHClient client, String path, File destination,
    {void Function(DownloadProgress)? onProgress}) async {
  fileDownloadCommand(path); // Validate before opening any channels.
  int? total;
  final quoted = "'${path.replaceAll("'", "'\\''")}'";
  // Size is advisory: transfer limits still apply if the file changes.
  try {
    total = await _fileSize(client, quoted);
  } catch (_) {
    // Hosts without stat still support byte-count progress.
  }
  if (total != null && total > maxDownloadBytes) {
    throw const FileDownloadException(
        'File exceeds the 100 MiB download limit.');
  }
  onProgress?.call(DownloadProgress(0, total));
  RandomAccessFile? file;
  try {
    file = await destination.open(mode: FileMode.write);
    await copyDownloadChunks(
      read: (offset) => _readDownloadChunk(client, path, offset),
      write: (bytes) async {
        await file!.writeFrom(bytes);
      },
      total: total,
      onProgress: onProgress,
    );
  } finally {
    await file?.close();
  }
}

/// Pull one bounded block at a time. Disk backpressure never pauses a large
/// SSH stdout stream (dartssh2 2.x cannot recover an exhausted paused window).
Future<void> copyDownloadChunks({
  required Future<List<int>> Function(int offset) read,
  required Future<void> Function(List<int>) write,
  int? total,
  void Function(DownloadProgress)? onProgress,
}) async {
  var received = 0;
  var stage = 'read';
  try {
    while (true) {
      stage = 'read';
      final bytes = await read(received);
      if (bytes.length > downloadChunkBytes ||
          received + bytes.length > maxDownloadBytes) {
        throw const FileDownloadException('File exceeds the download limit.');
      }
      stage = 'write';
      await write(bytes);
      received += bytes.length;
      onProgress?.call(DownloadProgress(received, total));
      if (bytes.length < downloadChunkBytes) break;
    }
    if (total != null && received != total) {
      throw const FileDownloadException(
          'Remote file changed or transfer was incomplete. Please retry.');
    }
  } catch (error) {
    throw FileDownloadException(
      'Download failed after $received bytes ($stage): $error',
      cause: error,
      received: received,
      stage: stage,
      exitCode: error is FileDownloadException ? error.exitCode : null,
    );
  }
}

Future<List<int>> _readDownloadChunk(
    SSHClient client, String path, int offset) async {
  var expired = false;
  final opening =
      client.execute(fileDownloadCommand(path, offset: offset)).then((session) {
    if (expired) session.channel.destroy();
    return session;
  });
  final session =
      await opening.timeout(const Duration(seconds: 15), onTimeout: () {
    expired = true;
    throw TimeoutException('Download channel open timed out');
  });
  final stderr = session.stderr.listen((_) {}, onError: (Object _) {});
  try {
    // Collection has no async disk writes, and each channel is capped well
    // below the 2 MiB receive window even if stream scheduling pauses it.
    final output = session.stdout.fold<BytesBuilder>(BytesBuilder(copy: false),
        (buffer, bytes) {
      if (buffer.length + bytes.length > downloadChunkBytes) {
        throw const FileDownloadException('Invalid download block size.');
      }
      return buffer..add(bytes);
    });
    final result = await (() async {
      final results = await Future.wait<Object?>(
          [output, session.stdin.close(), session.done]);
      final bytes = results.first! as BytesBuilder;
      if (session.exitCode != 0) {
        throw FileDownloadException(
            switch (session.exitCode) {
              44 => 'File does not exist on the connected SSH host.',
              45 => 'The link points to a directory, not a file.',
              46 => 'The SSH account cannot read this file.',
              _ =>
                'SSH file transfer failed (exit ${session.exitCode ?? "unknown"}).',
            },
            exitCode: session.exitCode);
      }
      return bytes.takeBytes();
    })()
        .timeout(const Duration(seconds: 30));
    return result;
  } finally {
    session.channel.destroy();
    await stderr.cancel();
  }
}

Future<int?> _fileSize(SSHClient client, String quoted) async {
  var expired = false;
  final opening = client
      .execute(_posixShellCommand('stat -Lc %s -- $quoted'))
      .then((session) {
    if (expired) session.channel.destroy();
    return session;
  });
  final session =
      await opening.timeout(const Duration(seconds: 15), onTimeout: () {
    expired = true;
    throw TimeoutException('File size lookup timed out');
  });
  final stderr = session.stderr.listen((_) {}, onError: (Object _) {});
  try {
    final bytes = <int>[];
    return await (() async {
      await session.stdin.close();
      await for (final chunk in session.stdout) {
        if (bytes.length + chunk.length > 128) return null;
        bytes.addAll(chunk);
      }
      await session.done;
      if (session.exitCode != 0) return null;
      final size = int.tryParse(String.fromCharCodes(bytes).trim());
      return size != null && size >= 0 ? size : null;
    })()
        .timeout(const Duration(seconds: 15));
  } finally {
    session.channel.destroy();
    await stderr.cancel();
  }
}
