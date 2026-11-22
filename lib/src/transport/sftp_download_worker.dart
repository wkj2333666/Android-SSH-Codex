import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../diagnostics.dart';
import '../profiles/host_profile.dart';
import '../profiles/profile_store.dart';
import 'connection_setup.dart';
import 'file_download.dart';
import 'resumable_download.dart';
import 'ssh_connector.dart';

/// SSH sockets, SFTP packets, and file buffers stay entirely in this isolate.
/// Only small progress and diagnostic messages cross back to Flutter.
Future<int> downloadSftpInWorker({
  required HostProfile profile,
  required HostSecret secret,
  required String? targetKey,
  required String? jumpKey,
  required String path,
  required String destination,
  required String purpose,
  required int maxBytes,
  required DownloadCancellation cancellation,
  void Function(DownloadProgress)? onProgress,
}) async {
  cancellation.check();
  final events = ReceivePort();
  SendPort? commands;
  final detach = cancellation.onCancel(() => commands?.send(null));
  Isolate? worker;
  final downloadWorkId = ++_nextDownloadWorkId;
  try {
    worker = await Isolate.spawn(
      _runDownload,
      (
        reply: events.sendPort,
        profile: profile,
        secret: secret,
        targetKey: targetKey,
        jumpKey: jumpKey,
        path: path,
        destination: destination,
        purpose: purpose,
        maxBytes: maxBytes,
      ),
      debugName: 'sftp-download',
      onExit: events.sendPort,
      onError: events.sendPort,
    );
    await for (final event in events) {
      if (event is SendPort) {
        commands = event;
        if (cancellation.isCancelled) event.send(null);
      } else if (event is DownloadProgress) {
        if (!cancellation.isCancelled) onProgress?.call(event);
      } else if (event is _Diagnostic) {
        Diagnostics.record(event.event, {
          ...event.fields,
          'downloadWorkId': downloadWorkId,
        });
      } else {
        // Every normal terminal message is sent with Isolate.exit, after the
        // worker has closed its transfer resources and stopped writing.
        cancellation.check();
        if (event is int) return event;
        if (event is DownloadCancelled) throw event;
        if (event is DownloadWorkerFailure) throw event;
        throw const FileDownloadException('The SFTP download worker stopped.');
      }
    }
    throw const FileDownloadException('The SFTP download worker stopped.');
  } finally {
    detach();
    events.close();
    worker?.kill();
  }
}

int _nextDownloadWorkId = 0;

typedef _DownloadRequest = ({
  SendPort reply,
  HostProfile profile,
  HostSecret secret,
  String? targetKey,
  String? jumpKey,
  String path,
  String destination,
  String purpose,
  int maxBytes,
});

final class _Diagnostic {
  const _Diagnostic(this.event, this.fields);

  final String event;
  final Map<String, Object?> fields;
}

final class DownloadWorkerFailure extends FileDownloadException {
  const DownloadWorkerFailure(super.message, this.diagnosticFields,
      {super.received, super.stage, super.exitCode});

  final Map<String, Object?> diagnosticFields;
}

Future<void> _runDownload(_DownloadRequest request) async {
  final commands = ReceivePort();
  final cancellation = DownloadCancellation();
  commands.listen((_) => cancellation.cancel());
  request.reply.send(commands.sendPort);
  final result = await Diagnostics.relayWhile(
    (event, fields) => request.reply.send(_Diagnostic(event, fields)),
    () => _transfer(request, cancellation),
  );
  commands.close();
  Isolate.exit(request.reply, result);
}

Future<Object> _transfer(
    _DownloadRequest request, DownloadCancellation cancellation) async {
  final profile = request.profile;
  final store = MemoryProfileStore();
  final targetKey = request.targetKey;
  final jumpKey = request.jumpKey;
  if (targetKey != null) {
    await store.writeHostFingerprint(profile.id, targetKey);
  }
  if (jumpKey != null) {
    await store.writeHostFingerprint('${profile.id}.jump', jumpKey);
  }
  final connector = SshConnector(store);
  final openings = <Future<void>>[];
  var retries = 0;
  try {
    await downloadResumableFile(
      connect: () {
        final opening = _open(request, connector, cancellation);
        openings.add(opening.then<void>((_) {}, onError: (Object _) {}));
        return opening;
      },
      destination: File(request.destination),
      cancellation: cancellation,
      onProgress: request.reply.send,
      onRetry: (attempt, bytes, error) {
        retries = attempt;
        Diagnostics.record('download.retry', {
          'purpose': request.purpose,
          'retry': attempt,
          'receivedBytes': bytes,
          ...Diagnostics.errorFields(error),
        });
      },
    );
    return retries;
  } on DownloadCancelled catch (error) {
    return error;
  } catch (error) {
    final transfer = error is FileDownloadException ? error : null;
    return DownloadWorkerFailure(
      transfer?.message ??
          (error is FileSystemException
              ? 'Phone storage could not be written. Check free space.'
              : 'SFTP download failed (${error.runtimeType}).'),
      Diagnostics.errorFields(transfer?.cause ?? error),
      received: transfer?.received ?? 0,
      stage: transfer?.stage,
      exitCode: transfer?.exitCode,
    );
  } finally {
    await boundedConnectionCleanup('downloadOpening', () async {
      await Future.wait(openings);
    });
  }
}

Future<DownloadSource> _open(_DownloadRequest request, SshConnector connector,
    DownloadCancellation cancellation) async {
  cancellation.check();
  final setup = ConnectionSetup(0);
  final detach = cancellation.onCancel(() => setup.cancel(DownloadCancelled()));
  try {
    final connection = await connector.connect(
      request.profile,
      request.secret,
      prompt: (_) async => false,
      diagnosticRole: request.purpose,
      setup: setup,
    );
    if (cancellation.isCancelled) {
      await connection.close(reason: 'download_cancelled');
      throw DownloadCancelled();
    }
    return await SftpDownloadSource.open(connection, request.path,
        maxBytes: request.maxBytes);
  } finally {
    detach();
    setup.dispose();
  }
}
