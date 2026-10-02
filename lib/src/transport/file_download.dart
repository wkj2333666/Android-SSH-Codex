import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

const maxDownloadBytes = 100 * 1024 * 1024;

String? remoteFilePath(String value, String cwd) {
  try {
    final uri = Uri.parse(value);
    if (uri.hasAuthority && !(uri.scheme == 'file' && uri.host.isEmpty))
      return null;
    if (uri.scheme.isNotEmpty &&
        uri.scheme != 'file' &&
        uri.scheme != 'sandbox') return null;
    var path =
        '${uri.path.startsWith('/') ? '/' : ''}${uri.pathSegments.join('/')}';
    if (path.isEmpty ||
        path.contains('\u0000') ||
        path.contains('\n') ||
        path.contains('\r')) return null;
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
  if (!path.startsWith('/') || path.contains('\u0000'))
    throw ArgumentError('Invalid path');
  final quoted = "'${path.replaceAll("'", "'\\''")}'";
  return 'test -f $quoted && head -c ${maxDownloadBytes + 1} -- $quoted';
}

Future<void> downloadRemoteFile(
    SSHClient client, String path, File destination) async {
  var timedOut = false;
  final opening = client.execute(fileDownloadCommand(path)).then((session) {
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
  try {
    file = await destination.open(mode: FileMode.write);
    await (() async {
      await session.stdin.close();
      await for (final chunk in session.stdout) {
        length += chunk.length;
        if (length > maxDownloadBytes) throw StateError('File exceeds 100 MiB');
        await file!.writeFrom(chunk);
      }
      await session.done;
      if (session.exitCode != 0) throw StateError('Remote file is unavailable');
    })()
        .timeout(const Duration(minutes: 2));
  } finally {
    session.close();
    await stderr.cancel();
    await file?.close();
  }
}
