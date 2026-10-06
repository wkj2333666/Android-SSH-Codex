import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:android_ssh_codex/src/transport/file_download.dart';
import 'package:android_ssh_codex/src/transport/resumable_download.dart';
import 'package:android_ssh_codex/src/transport/ssh_connector.dart';
import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

class MemorySource implements DownloadSource {
  MemorySource(this.bytes, {this.failAt, this.corrupt = false});
  final List<int> bytes;
  final int? failAt;
  final bool corrupt;
  bool closed = false;
  int active = 0;
  int peak = 0;
  final offsets = <int>[];
  @override
  Future<DownloadIdentity> identify() async =>
      DownloadIdentity(bytes.length, sha256.convert(bytes).toString());
  @override
  Future<List<int>> read(int offset, int length) async {
    offsets.add(offset);
    peak = ++active > peak ? active : peak;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      if (failAt != null && offset >= failAt!) {
        throw TimeoutException('simulated network loss');
      }
      final block = bytes.sublist(offset, offset + length);
      if (corrupt && block.isNotEmpty) block[0] ^= 1;
      return block;
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
  InterruptingSource(this.inner, this.client);
  final DownloadSource inner;
  final SSHClient client;
  @override
  Future<DownloadIdentity> identify() => inner.identify();
  @override
  Future<List<int>> read(int offset, int length) {
    final pending = inner.read(offset, length);
    if (offset >= 1024 * 1024) client.close();
    return pending;
  }

  @override
  Future<void> close() => inner.close();
}

void main() {
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
    expect(first.peak, 4);
    expect(second.peak, 4);
    expect(first.closed && second.closed, isTrue);
    expect(await output.readAsBytes(), bytes);
  });

  test('remote change refuses to splice different files', () async {
    var opens = 0;
    final changed = Uint8List.fromList(bytes)..[0] = 255;
    await expectLater(
        downloadResumableFile(
          connect: () async => ++opens == 1
              ? MemorySource(bytes, failAt: 1024 * 1024)
              : MemorySource(changed),
          destination: output,
          cancellation: DownloadCancellation(),
          retryDelay: Duration.zero,
        ),
        throwsA(isA<FileDownloadException>().having(
            (e) => e.message, 'message', contains('Remote file changed'))));
    expect(opens, 2);
    expect(await output.length(), 1024 * 1024);
  });

  test('same-length corrupted content fails final checksum', () async {
    await expectLater(
        downloadResumableFile(
          connect: () async => MemorySource(bytes, corrupt: true),
          destination: output,
          cancellation: DownloadCancellation(),
        ),
        throwsA(isA<FileDownloadException>().having(
            (e) => e.message, 'message', contains('checksum mismatch'))));
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
    await input.writeAsBytes(bytes);
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
        return connections == 1 ? InterruptingSource(source, client) : source;
      },
      destination: output,
      cancellation: DownloadCancellation(),
      operationTimeout: const Duration(seconds: 5),
      retryDelay: Duration.zero,
      onRetry: (_, received, __) => retries.add(received),
    );
    expect(connections, 2);
    expect(retries.single, greaterThanOrEqualTo(1024 * 1024));
    expect(await output.readAsBytes(), bytes);
    expect(active!.isClosed, isTrue);
    // Timing is diagnostic only; shared CI runners cannot prove phone speed.
    // ignore: avoid_print
    print(
        'SFTP resume verified: ${bytes.length} bytes, ${watch.elapsedMilliseconds} ms');
  },
      timeout: const Timeout(Duration(seconds: 90)),
      skip: !Platform.environment.containsKey('DOWNLOAD_TEST_KEY'));
}
