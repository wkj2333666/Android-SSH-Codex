import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

const maxDownloadBytes = 100 * 1024 * 1024;

class DownloadProgress {
  const DownloadProgress(this.received, this.total, {this.saving = false});
  final int received;
  final int? total;
  final bool saving;
}

class FileDownloadException implements Exception {
  const FileDownloadException(this.message);
  final String message;
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

String fileDownloadCommand(String path) {
  if (!path.startsWith('/') || path.contains('\u0000')) {
    throw ArgumentError('Invalid path');
  }
  final quoted = "'${path.replaceAll("'", "'\\''")}'";
  return 'if ! test -e $quoted; then exit 44; '
      'elif ! test -f $quoted; then exit 45; '
      'elif ! test -r $quoted; then exit 46; fi; '
      'head -c ${maxDownloadBytes + 1} -- $quoted';
}

Future<void> downloadRemoteFile(SSHClient client, String path, File destination,
    {void Function(DownloadProgress)? onProgress}) async {
  final command = fileDownloadCommand(path);
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
  var timedOut = false;
  final opening = client.execute(command).then((session) {
    if (timedOut) session.close();
    return session;
  });
  final session =
      await opening.timeout(const Duration(seconds: 15), onTimeout: () {
    timedOut = true;
    throw TimeoutException('Download channel timed out');
  });
  final stderr = session.stderr.listen((_) {}, onError: (Object _) {});
  RandomAccessFile? file;
  var length = 0;
  final updates = Stopwatch()..start();
  try {
    file = await destination.open(mode: FileMode.write);
    await (() async {
      await session.stdin.close();
      await for (final chunk in session.stdout) {
        length += chunk.length;
        if (length > maxDownloadBytes) {
          throw const FileDownloadException(
              'File exceeds the 100 MiB download limit.');
        }
        await file!.writeFrom(chunk);
        if (updates.elapsedMilliseconds >= 100) {
          onProgress?.call(DownloadProgress(length, total));
          updates.reset();
        }
      }
      await session.done;
      if (session.exitCode != 0) {
        throw FileDownloadException(switch (session.exitCode) {
          44 =>
            'File does not exist on the connected SSH host. A sandbox link may refer to a different machine.',
          45 => 'The link points to a directory, not a file.',
          46 => 'The SSH account cannot read this file.',
          _ =>
            'SSH file transfer failed (exit ${session.exitCode ?? "unknown"}).',
        });
      }
      onProgress?.call(DownloadProgress(length, total));
    })()
        .timeout(const Duration(minutes: 2));
  } finally {
    session.close();
    await stderr.cancel();
    await file?.close();
  }
}

Future<int?> _fileSize(SSHClient client, String quoted) async {
  var expired = false;
  final opening = client.execute('stat -Lc %s -- $quoted').then((session) {
    if (expired) session.close();
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
    session.close();
    await stderr.cancel();
  }
}
