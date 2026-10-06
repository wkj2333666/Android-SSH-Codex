import 'dart:io';

import 'package:android_ssh_codex/src/transport/file_download.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    expect(fileDownloadCommand("/tmp/a'\$(touch bad)"), contains("'\\''"));
    expect(fileDownloadCommand('/tmp/a'), contains('exit 44'));
    expect(fileDownloadCommand('/tmp/a'), contains('exit 45'));
    expect(fileDownloadCommand('/tmp/a'), contains('exit 46'));
    expect(fileDownloadCommand('/tmp/a'), startsWith('/bin/sh -c '));
    expect(fileDownloadCommand('/tmp/a'), contains('head -c 104857601 -- '));
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
