import 'package:android_ssh_codex/src/ports/port_discovery.dart';
import 'package:android_ssh_codex/src/profiles/host_profile.dart';
import 'package:android_ssh_codex/src/projects/remote_project.dart';
import 'package:android_ssh_codex/src/tasks/message_attachments.dart';
import 'package:android_ssh_codex/src/transport/file_download.dart';
import 'package:android_ssh_codex/src/transport/remote_path.dart';
import 'package:android_ssh_codex/src/ui/widgets/codex_directive_content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows drive paths translate only at the SFTP boundary', () {
    expect(remoteSftpPath(r'C:\Users\A B\file.bin'), '/C:/Users/A B/file.bin');
    expect(remoteSftpPath('/home/dev/file.bin'), '/home/dev/file.bin');
  });
  test('Windows listening ports normalize wildcard and IPv6 addresses', () {
    final ports = parseListeningPorts('TCP 0.0.0.0:3000 0.0.0.0:0 LISTENING\n'
        'TCP :::8080 0.0.0.0:0 LISTENING\n'
        'TCP 127.0.0.1:3000 0.0.0.0:0 LISTENING\n'
        'TCP 127.0.0.1:9000 0.0.0.0:0 ESTABLISHED\n');
    expect(ports.map((p) => p.address), ['127.0.0.1:3000', '[::1]:8080']);
  });
  test('Windows attachments and visualization paths are presented as files',
      () {
    final message = parseAttachmentMessage(
        'Look at this\n\nAttached files (on the remote machine):\nC:/Users/me/file-report.pdf');
    expect(message.text, 'Look at this');
    expect(message.attachments.single.path, 'C:/Users/me/file-report.pdf');
    expect(const MessageAttachment(path: r'C:\Projects\report.pdf').label,
        'report.pdf');
    final content = parseCodexDirectiveContent(
        '\uE200visualize\uE202{"path":"C:/Projects/plot.html"}\uE201');
    expect(content.visualizations.single.path, 'C:/Projects/plot.html');
  });
  test('Windows hosts survive profile persistence without changing old hosts',
      () {
    final json = {
      'id': 'windows',
      'label': 'Windows',
      'hostName': 'host.example',
      'user': 'developer',
      'port': 22,
      'remotePlatform': 'windows',
    };
    expect(HostProfile.fromJson(json).toJson()['remotePlatform'], 'windows');
    expect(HostProfile.fromJson(json).copyWith(label: 'Edited').remotePlatform,
        RemotePlatform.windows);
    json.remove('remotePlatform');
    expect(HostProfile.fromJson(json).remotePlatform, RemotePlatform.posix);
  });

  test('Windows file links keep their drive and decode file URLs', () {
    expect(remoteFilePath(r'D:\Projects\demo\main.dart:12', r'D:\Projects'),
        'D:/Projects/demo/main.dart');
    expect(remoteFilePath('file:///C:/Users/A%20B/report.pdf', ''),
        'C:/Users/A B/report.pdf');
    expect(remoteFilePath('src/main.dart', r'D:\Projects\demo'),
        'D:/Projects/demo/src/main.dart');
    expect(remoteFilePath('../report.pdf', 'D:/Projects/demo'),
        'D:/Projects/report.pdf');
  });

  test('Windows paths cannot become URLs or drive-relative file reads', () {
    expect(remoteFilePath('https://example.com/file', 'D:/Projects'), isNull);
    expect(remoteFilePath('D:secret.txt', 'D:/Projects'), isNull);
    expect(remoteFilePath(r'\\server\share\secret.txt', 'D:/Projects'), isNull);
    expect(remoteFilePath('D:/bad\npath', ''), isNull);
  });

  test('Windows project directories normalize separators and preserve roots',
      () {
    expect(normalizeRemoteCwd(r'D:\Projects\demo\'), 'D:/Projects/demo');
    expect(normalizeRemoteCwd('D:/'), 'D:/');
    expect(normalizeRemoteCwd('/home/dev/demo/'), '/home/dev/demo');
  });
}
