import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:android_ssh_codex/src/diagnostics.dart';
import 'package:android_ssh_codex/src/profiles/host_profile.dart';
import 'package:android_ssh_codex/src/transport/file_download.dart';
import 'package:android_ssh_codex/src/transport/resumable_download.dart';
import 'package:android_ssh_codex/src/transport/sftp_download_worker.dart';
import 'package:android_ssh_codex/src/transport/ssh_connector.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

class MemorySource implements DownloadSource {
  MemorySource(this.bytes,
      {this.failAt,
      this.modifiedAt = 1,
      this.endingModifiedAt,
      this.beforeRead});
  final List<int> bytes;
  final int? failAt;
  final int? modifiedAt;
  final int? endingModifiedAt;
  final Future<void> Function(int)? beforeRead;
  bool closed = false;
  int active = 0;
  int stats = 0;
  int peak = 0;
  final offsets = <int>[];
  @override
  Future<DownloadMetadata> metadata() async {
    final modified = ++stats == 1 ? modifiedAt : endingModifiedAt ?? modifiedAt;
    return DownloadMetadata(bytes.length, modified);
  }

  @override
  Future<List<int>> read(int offset, int length) async {
    offsets.add(offset);
    peak = ++active > peak ? active : peak;
    try {
      await beforeRead?.call(offset);
      await Future<void>.delayed(const Duration(milliseconds: 1));
      if (failAt != null && offset >= failAt!) {
        throw TimeoutException('simulated network loss');
      }
      return bytes.sublist(offset, offset + length);
    } finally {
      active--;
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class InterruptingSource implements DownloadSource {
  InterruptingSource(this.inner, this.client, this.breakAt);
  final DownloadSource inner;
  final SSHClient client;
  final int breakAt;
  @override
  Future<DownloadMetadata> metadata() => inner.metadata();
  @override
  Future<List<int>> read(int offset, int length) {
    final pending = inner.read(offset, length);
    if (offset >= breakAt) client.close();
    return pending;
  }

  @override
  Future<void> close() => inner.close();
}

void main() {
  const windowBytes = resumableReadBytes * resumableReadWindow;
  late Directory directory;
  late File output;
  final bytes =
      Uint8List.fromList(List.generate(3 * 1024 * 1024 + 31, (i) => i % 251));
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('resumable-test-');
    output = File('${directory.path}/output');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('bounded pipeline resumes at committed offset, preserves exact bytes',
      () async {
    final first = MemorySource(bytes, failAt: 1024 * 1024);
    final second = MemorySource(bytes);
    var opens = 0;
    final retries = <int>[];
    await downloadResumableFile(
      connect: () async => ++opens == 1 ? first : second,
      destination: output,
      cancellation: DownloadCancellation(),
      retryDelay: Duration.zero,
      onRetry: (_, received, __) => retries.add(received),
    );
    expect(retries, [1024 * 1024]);
    expect(second.offsets.first, 1024 * 1024);
    expect(first.peak, greaterThan(4));
    expect(second.peak, greaterThan(4));
    expect(first.peak, lessThanOrEqualTo(resumableReadWindow));
    expect(second.peak, lessThanOrEqualTo(resumableReadWindow));
    expect(first.closed && second.closed, isTrue);
    expect(first.stats, 1);
    expect(second.stats, 2);
    expect(await output.readAsBytes(), bytes);
  });

  test('request window refills without waiting for the rest of the batch',
      () async {
    final initialWindow = Completer<void>();
    final refilled = Completer<void>();
    final firstBlock = Completer<void>();
    final secondBlock = Completer<void>();
    final payload = Uint8List(windowBytes + 3 * resumableReadBytes)..[0] = 117;
    final source = MemorySource(payload, beforeRead: (offset) async {
      if (offset == windowBytes - resumableReadBytes) initialWindow.complete();
      if (offset == windowBytes) refilled.complete();
      if (offset == 0) await firstBlock.future;
      if (offset == resumableReadBytes) await secondBlock.future;
    });
    final transferring = downloadResumableFile(
      connect: () async => source,
      destination: output,
      cancellation: DownloadCancellation(),
    );
    try {
      await initialWindow.future.timeout(const Duration(seconds: 3));
      expect(source.offsets.length, resumableReadWindow);
      firstBlock.complete();
      await refilled.future.timeout(const Duration(seconds: 3));
      expect(source.offsets.length, resumableReadWindow + 1);
      expect(await output.length(), 0); // The second block still gates writes.
    } finally {
      if (!firstBlock.isCompleted) firstBlock.complete();
      secondBlock.complete();
      await transferring;
    }
    expect(await output.readAsBytes(), payload);
  });

  for (final mtime in <int?>[2, null]) {
    test('restarts without splicing when the new modification time is $mtime',
        () async {
      var opens = 0;
      final changed = Uint8List.fromList(bytes)..[0] = 255;
      final second = MemorySource(changed, modifiedAt: mtime);
      await downloadResumableFile(
          connect: () async =>
              ++opens == 1 ? MemorySource(bytes, failAt: 1024 * 1024) : second,
          destination: output,
          cancellation: DownloadCancellation(),
          retryDelay: Duration.zero);
      expect(opens, 2);
      expect(second.offsets.first, 0);
      expect(await output.readAsBytes(), changed);
    });
  }

  test('restart truncates the old prefix when a reconnected file is smaller',
      () async {
    var opens = 0;
    final smaller = MemorySource([9, 10]);
    await downloadResumableFile(
      connect: () async =>
          ++opens == 1 ? MemorySource(bytes, failAt: 1024 * 1024) : smaller,
      destination: output,
      cancellation: DownloadCancellation(),
      retryDelay: Duration.zero,
    );
    expect(smaller.offsets.first, 0);
    expect(await output.readAsBytes(), [9, 10]);
  });

  test('refuses to publish a file modified during transfer', () async {
    await expectLater(
        downloadResumableFile(
          connect: () async => MemorySource(bytes, endingModifiedAt: 2),
          destination: output,
          cancellation: DownloadCancellation(),
        ),
        throwsA(isA<FileDownloadException>().having(
            (e) => e.message, 'message', contains('Remote file changed'))));
  });

  test('cancellation closes the source without subsequent writes', () async {
    final cancellation = DownloadCancellation();
    final source = MemorySource(bytes);
    await expectLater(
        downloadResumableFile(
          connect: () async => source,
          destination: output,
          cancellation: cancellation,
          onProgress: (progress) {
            if (progress.received > 0) cancellation.cancel();
          },
        ),
        throwsA(isA<DownloadCancelled>()));
    final length = await output.length();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await output.length(), length);
    expect(source.closed, isTrue);
  });

  test('late-opened connection after cancellation is closed', () async {
    final opening = Completer<DownloadSource>();
    final entered = Completer<void>();
    final cancellation = DownloadCancellation();
    final source = MemorySource(bytes);
    final download = downloadResumableFile(
        connect: () {
          entered.complete();
          return opening.future;
        },
        destination: output,
        cancellation: cancellation);
    final result = expectLater(download, throwsA(isA<DownloadCancelled>()));
    await entered.future;
    cancellation.cancel();
    await result;
    opening.complete(source);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(source.closed, isTrue);
  });

  test('real SFTP resumes after socket closure and verifies binary content',
      () async {
    final input = File('${directory.path}/' r'''a' "$x; & `id`.bin''');
    final payload = Uint8List.fromList(
        List.generate(10 * 1024 * 1024 + 31, (i) => i % 251));
    await input.writeAsBytes(payload);
    SSHClient? active;
    var connections = 0;
    final retries = <int>[];
    final watch = Stopwatch()..start();
    await downloadResumableFile(
      connect: () async {
        connections++;
        final client = SSHClient(
          await SSHSocket.connect('127.0.0.1', 22229),
          username: Platform.environment['USER']!,
          identities: SSHKeyPair.fromPem(
              await File(Platform.environment['DOWNLOAD_TEST_KEY']!)
                  .readAsString()),
        );
        active = client;
        final source = await SftpDownloadSource.open(
            SshConnection(client: client), input.path);
        return connections == 1
            ? InterruptingSource(source, client, windowBytes + 1280 * 1024)
            : source;
      },
      destination: output,
      cancellation: DownloadCancellation(),
      operationTimeout: const Duration(seconds: 5),
      retryDelay: Duration.zero,
      onRetry: (_, received, __) => retries.add(received),
    );
    expect(connections, 2);
    expect(retries.single, greaterThanOrEqualTo(1024 * 1024));
    expect(await output.readAsBytes(), payload);
    expect(active!.isClosed, isTrue);
    // Timing is diagnostic only; shared CI runners cannot prove phone speed.
    // ignore: avoid_print
    print(
        'SFTP resume verified: ${payload.length} bytes, ${watch.elapsedMilliseconds} ms');
  },
      timeout: const Timeout(Duration(seconds: 90)),
      skip: !Platform.environment.containsKey('DOWNLOAD_TEST_KEY'));

  test(
      'worker SFTP matches curl on the same SSH server and uses the stored pin',
      () async {
    final input = File('${directory.path}/curl baseline.bin');
    final payload =
        Uint8List.fromList(List.generate(3 * 1024 * 1024 + 11, (i) => i % 251));
    await input.writeAsBytes(payload);
    final keyPath = Platform.environment['DOWNLOAD_TEST_KEY']!;
    final fixturePin = Platform.environment['DOWNLOAD_TEST_HOST_KEY']!;
    final user = Platform.environment['USER']!;
    final uri =
        Uri(scheme: 'sftp', host: '127.0.0.1', port: 22229, path: input.path);
    final curlFile = File('${directory.path}/curl');
    // curl's key pin CLI depends on its SSH backend. This is an ephemeral,
    // loopback-only fixture with a generated key, not the app's host policy.
    final curl = await Process.run('/usr/bin/curl', [
      '--disable',
      '--noproxy',
      '*',
      '--insecure',
      '--silent',
      '--show-error',
      '--max-time',
      '20',
      '--user',
      '$user:',
      '--key',
      keyPath,
      '--pubkey',
      '$keyPath.pub',
      '--output',
      curlFile.path,
      uri.toString(),
    ]);
    expect(curl.exitCode, 0, reason: curl.stderr.toString());
    final profile = HostProfile(
      id: 'sftp-worker-test',
      label: 'Loopback SSH test',
      hostName: '127.0.0.1',
      user: user,
      port: 22229,
    );
    final secret = HostSecret(privateKey: await File(keyPath).readAsString());
    final hostKey = formatHostKeyFingerprint(utf8.encode(fixturePin));
    Future<int> run(String? pin, DownloadCancellation cancellation,
            {void Function(DownloadProgress)? onProgress}) =>
        downloadSftpInWorker(
          profile: profile,
          secret: secret,
          targetKey: pin,
          jumpKey: null,
          path: input.path,
          destination: output.path,
          purpose: 'download-test',
          maxBytes: maxDownloadBytes,
          cancellation: cancellation,
          onProgress: onProgress,
        );
    await expectLater(run(null, DownloadCancellation()),
        throwsA(isA<DownloadWorkerFailure>()));
    expect(await output.length(), 0);
    final diagnostics = <String>[];
    final progress = <DownloadProgress>[];
    final retries = await Diagnostics.relayWhile((event, fields) {
      if (fields.containsKey('downloadWorkId')) diagnostics.add(event);
    }, () => run(hostKey, DownloadCancellation(), onProgress: progress.add));
    expect(retries, 0);
    expect(diagnostics, contains('ssh.open'));
    expect(progress.any((status) => status.received > 0), isTrue);
    final downloaded = await output.readAsBytes();
    expect(downloaded, payload);
    expect(downloaded, await curlFile.readAsBytes());

    final cancellation = DownloadCancellation();
    await expectLater(
        run(hostKey, cancellation, onProgress: (progress) {
          if (progress.checking) cancellation.cancel();
        }),
        throwsA(isA<DownloadCancelled>()));
  },
      timeout: const Timeout(Duration(seconds: 90)),
      skip: !Platform.environment.containsKey('DOWNLOAD_TEST_HOST_KEY'));
}
