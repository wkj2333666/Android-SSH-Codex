import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:android_ssh_codex/src/transport/file_download.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dartssh2/dartssh2.dart';

void main() {
  test('bounded transfer passes 2 MiB with slow disk backpressure', () async {
    final source = List<int>.generate(3 * 1024 * 1024 + 123, (i) => i % 251);
    final output = BytesBuilder();
    var writing = false;
    await copyDownloadChunks(
      total: source.length,
      read: (offset) async {
        expect(writing, isFalse);
        expect(offset, output.length);
        return source.sublist(
            offset, (offset + downloadChunkBytes).clamp(0, source.length));
      },
      write: (bytes) async {
        writing = true;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        output.add(bytes);
        writing = false;
      },
    );
    expect(output.takeBytes(), source);
  });

  test('failed reads preserve offset and cause; never write after failure',
      () async {
    var writes = 0;
    final cause = TimeoutException('stalled');
    await expectLater(
        copyDownloadChunks(
          read: (offset) async {
            if (offset > 0) throw cause;
            return Uint8List(downloadChunkBytes);
          },
          write: (_) async {
            writes++;
          },
        ),
        throwsA(isA<FileDownloadException>()
            .having((e) => e.received, 'received', downloadChunkBytes)
            .having((e) => e.cause, 'cause', same(cause))));
    expect(writes, 1);
  });

  test('truncated remote file is not reported as successful', () async {
    await expectLater(
        copyDownloadChunks(
          total: 100,
          read: (_) async => [1, 2],
          write: (_) async {},
        ),
        throwsA(isA<FileDownloadException>()));
  });

  test('real SSH binary download crosses receive-window boundary', () async {
    final directory = await Directory.systemTemp.createTemp('download-ssh-');
    final client = SSHClient(
      await SSHSocket.connect('127.0.0.1', 22229),
      username: Platform.environment['USER']!,
      identities: SSHKeyPair.fromPem(
          await File(Platform.environment['DOWNLOAD_TEST_KEY']!)
              .readAsString()),
    );
    try {
      final source = Uint8List.fromList(
          List<int>.generate(4 * 1024 * 1024 + 37, (i) => i % 251));
      final input = File('${directory.path}/' r'''a' "$x; & `id`.bin''');
      final output = File('${directory.path}/download.bin');
      final stalled = File('${directory.path}/stall-transfer');
      await stalled.writeAsBytes([1]);
      await expectLater(
          downloadRemoteFile(client, stalled.path, output),
          throwsA(isA<FileDownloadException>()
              .having((e) => e.cause, 'cause', isA<TimeoutException>())));
      expect(await output.length(), 0);
      // A timed-out channel must not poison the shared SSH connection or
      // leave a writer that can mutate the next download's destination.
      await input.writeAsBytes(source);
      final progress = <int>[];
      await downloadRemoteFile(client, input.path, output,
          onProgress: (p) => progress.add(p.received));
      expect(await output.readAsBytes(), source);
      expect(progress.last, source.length);
      expect(progress.length, greaterThan(16));
    } finally {
      client.close();
      await directory.delete(recursive: true);
    }
  },
      timeout: const Timeout(Duration(seconds: 90)),
      skip: !Platform.environment.containsKey('DOWNLOAD_TEST_KEY'));

  test('remote artifact links resolve without treating them as phone paths',
      () {
    expect(remoteFilePath('sandbox:/mnt/data/report.pdf', '/project'),
        '/mnt/data/report.pdf');
    expect(remoteFilePath('file:///tmp/a%20b.txt', '/project'), '/tmp/a b.txt');
    expect(remoteFilePath('./out/a.zip', '/project'), '/project/out/a.zip');
    expect(
        remoteFilePath('/project/main.dart:12#L12', '/'), '/project/main.dart');
    expect(remoteFilePath('/tmp/a%2520b', '/'), '/tmp/a%20b');
    for (final path in [
      'https://example.com/a',
      'file://other/tmp/a',
      'javascript:alert(1)',
      '//other/a',
      '/tmp/%00'
    ]) {
      expect(remoteFilePath(path, '/project'), isNull);
    }
  });

  test('download command quotes shell metacharacters and bounds output', () {
    expect(fileDownloadCommand('/tmp/a'), contains(r'exit\ 44'));
    expect(fileDownloadCommand('/tmp/a'), contains(r'exit\ 45'));
    expect(fileDownloadCommand('/tmp/a'), contains(r'exit\ 46'));
    expect(fileDownloadCommand('/tmp/a'), startsWith('/bin/sh -c '));
    expect(
        fileDownloadCommand('/tmp/a'), contains(r'head\ -c\ 104857601\ --\ '));
    expect(() => fileDownloadCommand('relative'), throwsArgumentError);
  });

  for (final shell in ['/bin/sh', '/bin/bash', '/usr/bin/fish']) {
    test('download command works through $shell with quoted paths', () async {
      final directory =
          await Directory.systemTemp.createTemp('download-shell-');
      try {
        final file = File('${directory.path}/' r'''a' "$x; & `id`.bin''');
        final bytes = [0, 1, 10, 13, 127, 128, 255];
        await file.writeAsBytes(bytes);
        final result = await Process.run(
            shell, ['-c', fileDownloadCommand(file.path)],
            stdoutEncoding: null);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(result.stdout, bytes);
        final missing = await Process.run(
            shell, ['-c', fileDownloadCommand('${directory.path}/missing')]);
        expect(missing.exitCode, 44);
        final folder = await Process.run(
            shell, ['-c', fileDownloadCommand(directory.path)]);
        expect(folder.exitCode, 45);
      } finally {
        await directory.delete(recursive: true);
      }
    }, skip: !Platform.isLinux);
  }
}
