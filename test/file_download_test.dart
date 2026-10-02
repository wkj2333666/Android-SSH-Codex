import 'package:android_ssh_codex/src/transport/file_download.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('remote artifact links resolve without treating them as phone paths', () {
    expect(remoteFilePath('sandbox:/mnt/data/report.pdf', '/project'), '/mnt/data/report.pdf');
    expect(remoteFilePath('file:///tmp/a%20b.txt', '/project'), '/tmp/a b.txt');
    expect(remoteFilePath('./out/a.zip', '/project'), '/project/out/a.zip');
    expect(remoteFilePath('/project/main.dart:12#L12', '/'), '/project/main.dart');
    expect(remoteFilePath('/tmp/a%2520b', '/'), '/tmp/a%20b');
    for (final path in ['https://example.com/a', 'file://other/tmp/a', 'javascript:alert(1)', '//other/a', '/tmp/%00']) {
      expect(remoteFilePath(path, '/project'), isNull);
    }
  });

  test('download command quotes shell metacharacters and bounds output', () {
    expect(fileDownloadCommand("/tmp/a'\$(touch bad)"), contains("'\\''"));
    expect(fileDownloadCommand('/tmp/a'), 'test -f \'/tmp/a\' && head -c 104857601 -- \'/tmp/a\'');
    expect(() => fileDownloadCommand('relative'), throwsArgumentError);
  });
}
