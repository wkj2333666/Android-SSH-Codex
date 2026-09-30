import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../attachments.dart';

String attachmentUploadCommand(String token, String name) {
  if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(token)) {
    throw ArgumentError('Invalid attachment token');
  }
  final safeName = name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  final fileName = safeName.isEmpty ? 'attachment' : safeName.substring(0, min(100, safeName.length));
  final relative = '.local/share/android-ssh-codex/attachments';
  return 'umask 077; '
      'mkdir -p "\$HOME/$relative" && '
      'mkdir "\$HOME/$relative/$token" && '
      'cat > "\$HOME/$relative/$token/file-$fileName" && '
      'printf "%s" "\$HOME/$relative/$token/file-$fileName"';
}

Future<RemoteAttachment> uploadAttachment(SSHClient client, LocalAttachment attachment) async {
  Attachments.validate([attachment]);
  final random = Random.secure();
  final token = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  var openingTimedOut = false;
  final opening = client.execute(attachmentUploadCommand(token, attachment.name)).then((session) {
    if (openingTimedOut) session.close();
    return session;
  });
  final session = await opening.timeout(const Duration(seconds: 15), onTimeout: () {
    openingTimedOut = true;
    throw TimeoutException('Attachment channel timed out');
  });
  StreamSubscription<Uint8List>? stdout;
  StreamSubscription<Uint8List>? stderr;
  final output = BytesBuilder(copy: false);
  var outputLength = 0;
  final stdoutDone = Completer<void>();
  Object? readError;
  try {
    stdout = session.stdout.listen((chunk) {
      if (outputLength + chunk.length <= 8192) output.add(chunk);
      outputLength += chunk.length;
    }, onDone: stdoutDone.complete, onError: (Object error) {
      readError = error;
      if (!stdoutDone.isCompleted) stdoutDone.complete();
    }, cancelOnError: true);
    stderr = session.stderr.listen((_) {}, onError: (Object _) {});
    await Future.wait<void>([
      (() async {
        await session.stdin.addStream(Stream<Uint8List>.value(attachment.bytes));
        await session.stdin.close();
      })(),
      session.done,
      stdoutDone.future,
    ], eagerError: true).timeout(const Duration(seconds: 60));
    if (readError != null || session.exitCode != 0 || outputLength > 8192) {
      throw StateError('Attachment upload failed.');
    }
    final path = utf8.decode(output.takeBytes());
    if (!path.startsWith('/') || path.contains('\n') || path.contains('\r')) {
      throw StateError('Invalid remote attachment path.');
    }
    return RemoteAttachment(path: path, isImage: attachment.isImage);
  } finally {
    session.close();
    await stdout?.cancel();
    await stderr?.cancel();
  }
}
