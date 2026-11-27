import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/profiles/host_profile.dart';
import 'package:android_ssh_codex/src/transport/anonymous_workspace.dart';
import 'package:android_ssh_codex/src/transport/attachment_upload.dart';
import 'package:android_ssh_codex/src/transport/codex_daemon.dart';
import 'package:android_ssh_codex/src/transport/windows_commands.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const elevatedDaemonError = 'Error: start the Windows daemon from a '
      'non-elevated terminal; shared clients must not inherit administrator privileges';

  test('Windows elevated Shared failure explains explicit Custom setup',
      () async {
    var calls = 0;
    await expectLater(
      CodexDaemon.startShared((command, {environment}) async {
        calls++;
        return SshCommandResult(
            stdout: [],
            stderr: utf8.encode(elevatedDaemonError),
            exitCode: 1,
            exitSignal: null);
      }, environment: const {}, platform: RemotePlatform.windows),
      throwsA(isA<CodexBootstrapException>()
          .having((e) => e.reason, 'reason', 'shared_start_elevated')
          .having((e) => e.exitCode, 'exitCode', 1)
          .having(
              (e) => e.message,
              'guidance',
              allOf(
                  contains('non-administrator'),
                  contains('same Windows user'),
                  contains('codex app-server daemon start'),
                  contains('Custom'),
                  contains('socketPath')))),
    );
    expect(calls, 1,
        reason: 'Never switch modes or probe another socket implicitly.');
  });

  for (final example in [
    (platform: RemotePlatform.windows, error: 'Access denied.'),
    (platform: RemotePlatform.posix, error: elevatedDaemonError),
  ]) {
    test(
        '${example.platform.name} unrelated failure keeps its original diagnostic',
        () async {
      await expectLater(
        CodexDaemon.startShared(
            (command, {environment}) async => SshCommandResult(
                stdout: [],
                stderr: utf8.encode(example.error),
                exitCode: 1,
                exitSignal: null),
            environment: const {},
            platform: example.platform),
        throwsA(isA<CodexBootstrapException>()
            .having((e) => e.reason, 'reason', 'shared_start_failed')
            .having((e) => e.message, 'message', contains(example.error))),
      );
    });
  }

  test(
      'Windows uploads resume without truncation and private workspaces are unique',
      () async {
    final temp = await Directory.systemTemp.createTemp('windows-files.');
    try {
      const token = '0123456789abcdef0123456789abcdef';
      final command = _inDirectory(
          attachmentUploadCommand(token, 'report.bin',
              platform: RemotePlatform.windows),
          temp.path);
      final first = await _run(command);
      expect(first.exitCode, 0, reason: first.stderr.toString());
      final file = File(first.stdout as String);
      final bytes = List.generate(257, (i) => i % 256);
      await file.writeAsBytes(bytes);
      final second = await _run(command);
      expect(second.exitCode, 0, reason: second.stderr.toString());
      expect(second.stdout, first.stdout);
      expect(await file.readAsBytes(), bytes);
      final preview = await Process.run('powershell.exe',
          windowsReadFileCommand(file.path, 123).split(' ').skip(1).toList(),
          stdoutEncoding: null, stderrEncoding: null);
      expect(preview.exitCode, 0);
      expect(preview.stdout, bytes.take(123).toList());
      final workspace =
          _inDirectory(windowsAnonymousWorkspaceCommand(), temp.path);
      final a = await _run(workspace);
      final b = await _run(workspace);
      expect(a.exitCode, 0, reason: a.stderr.toString());
      expect(b.exitCode, 0, reason: b.stderr.toString());
      expect(a.stdout, isNot(b.stdout));
      expect(isAnonymousWorkspacePath(a.stdout as String), isTrue);
      final root = Directory('${temp.path}/android-ssh-codex');
      expect(await root.exists(), isTrue);
    } finally {
      await temp.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);

  test('Windows proxy supports consecutive interactive binary requests',
      () async {
    final temp = await Directory.systemTemp.createTemp('windows-roundtrips.');
    Process? process;
    StreamIterator<List<int>>? output;
    var exited = false;
    try {
      final exe = '${temp.path}/echo.exe';
      const program = r'''
public static class Echo {
  [System.Runtime.InteropServices.DllImport("kernel32.dll")]
  static extern System.IntPtr GetStdHandle(int id);
  [System.Runtime.InteropServices.DllImport("kernel32.dll")]
  static extern bool ReadFile(System.IntPtr file, byte[] data, int size, out int count, System.IntPtr overlapped);
  [System.Runtime.InteropServices.DllImport("kernel32.dll")]
  static extern bool WriteFile(System.IntPtr file, byte[] data, int size, out int count, System.IntPtr overlapped);
  public static int Main() {
    var data = new byte[1];
    for (int round = 0; round < 3; round++) {
      int count;
      if (!ReadFile(GetStdHandle(-10), data, 1, out count, System.IntPtr.Zero) || count != 1) return 9;
      if (!WriteFile(GetStdHandle(-11), data, 1, out count, System.IntPtr.Zero) || count != 1) return 10;
    }
    return 0;
  }
}
''';
      final compiled = await _run(powershellCommand(
          'Add-Type -TypeDefinition ${powershellLiteral(program)} '
          '-OutputAssembly ${powershellLiteral(exe)} -OutputType ConsoleApplication'));
      expect(compiled.exitCode, 0, reason: compiled.stderr.toString());
      final command =
          powershellCommand('\$codexExecutable = ${powershellLiteral(exe)}\n'
              r'$codexPrefix = @(); $codexArguments = @()'
              '\n'
              '$windowsProcessRelayScript');
      process = await Process.start(
          'powershell.exe', command.split(' ').skip(1).toList());
      final errors = process.stderr.drain<void>();
      output = StreamIterator(process.stdout);
      for (final value in [42, 0, 255]) {
        process.stdin.add([value]);
        await process.stdin.flush();
        expect(
            await output.moveNext().timeout(const Duration(seconds: 8),
                onTimeout: () =>
                    throw TimeoutException('No reply for byte $value')),
            isTrue);
        expect(output.current, [value]);
      }
      expect(await process.exitCode.timeout(const Duration(seconds: 5)), 0);
      exited = true;
      await errors;
    } finally {
      if (process != null) {
        if (!exited) {
          await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
        }
        await process.stdin.close().catchError((_) {});
      }
      await output?.cancel();
      await temp.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);

  test('Windows native argv preserves spaces, quotes, and metacharacters',
      () async {
    final temp = await Directory.systemTemp.createTemp('windows-argv.');
    try {
      final file = File('${temp.path}/echo.ps1');
      await file.writeAsString(
          r'param([string]$value) [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false); [Console]::Write($value)');
      const value = 'C:\\Users\\A B & %PATH% \' 中文\\socket.sock';
      final command = powershellCommand(
          r'$codexExecutable=(Get-Command powershell.exe).Source'
          '\n'
          '\$codexPrefix=@(\'-NoProfile\',\'-File\',${powershellLiteral(file.path)})\n'
          '\$codexArguments=@(${powershellLiteral(value)})\n'
          '$windowsProcessRelayScript');
      final result = await _run(command);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(result.stdout, value);
    } finally {
      await temp.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);
  test('proxy forwards a short request before SSH stdin closes', () async {
    const echo =
        r'$i=[Console]::OpenStandardInput();$o=[Console]::OpenStandardOutput();$b=$i.ReadByte();$o.WriteByte([byte]$b);$o.Flush();exit 0';
    final encoded = base64Encode([
      for (final unit in echo.codeUnits) ...[unit & 255, unit >> 8]
    ]);
    final command = powershellCommand(
        r'$codexExecutable=(Get-Command powershell.exe).Source'
        '\n'
        r'$codexPrefix=@()'
        '\n'
        '\$codexArguments=@(\'-NoProfile\',\'-NonInteractive\',\'-EncodedCommand\',\'$encoded\')\n'
        '$windowsProcessRelayScript');
    final process = await Process.start(
        'powershell.exe', command.split(' ').skip(1).toList());
    final errors = process.stderr.drain<void>();
    try {
      process.stdin.add([42]);
      await process.stdin.flush();
      final bytes =
          await process.stdout.first.timeout(const Duration(seconds: 8));
      expect(bytes, [42]);
      expect(await process.exitCode.timeout(const Duration(seconds: 5)), 0);
    } finally {
      await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
      await process.stdin.close().catchError((_) {});
      await errors;
    }
  }, skip: !Platform.isWindows);
  test('Windows shared startup accepts drive paths and preserves environment',
      () async {
    const environment = {'CODEX_HOME': r'C:\Users\A B\.codex'};
    final path = await CodexDaemon.startShared((command, {environment}) async {
      expect(
          command,
          startsWith(
              'powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand '));
      expect(command.length, lessThan(8191));
      expect(environment, {'CODEX_HOME': r'C:\Users\A B\.codex'});
      return SshCommandResult(
          stdout: utf8.encode(
              jsonEncode({'socketPath': r'C:\Users\A B\.codex\app.sock'})),
          stderr: [],
          exitCode: 0,
          exitSignal: null);
    }, environment: environment, platform: RemotePlatform.windows);
    expect(path, r'C:\Users\A B\.codex\app.sock');
  });

  test(
      'Windows custom mode validates local absolute paths without starting a daemon',
      () async {
    final profile = HostProfile(
        id: 'win',
        label: 'Windows',
        hostName: 'host',
        user: 'dev',
        port: 22,
        remotePlatform: RemotePlatform.windows,
        appServerMode: AppServerMode.custom,
        customAppServerSocket: r'C:\Users\dev\app.sock');
    Future<SshCommandResult> neverRun(String command,
            {Map<String, String>? environment}) async =>
        throw StateError('Must not run');
    expect(await resolveCodexSocketForProfile(neverRun, profile),
        r'C:\Users\dev\app.sock');
    for (final path in [
      'relative.sock',
      '/tmp/app.sock',
      r'\\host\share\app.sock',
      'C:relative.sock',
      'C:/bad\n.sock'
    ]) {
      await expectLater(
          resolveCodexSocketForProfile(
              neverRun, profile.copyWith(customAppServerSocket: path)),
          throwsA(isA<CodexBootstrapException>()));
    }
    await expectLater(
        resolveCodexSocketForProfile(
            neverRun, profile.copyWith(appServerMode: AppServerMode.isolated)),
        throwsA(isA<CodexBootstrapException>()));
  });

  test('PowerShell wrapper preserves Unicode and shell metacharacters',
      () async {
    const value = '中文 & | %PATH% \$() ` " \' 🦀';
    final command =
        powershellCommand('[Console]::Write(${powershellLiteral(value)})');
    final result = await Process.run('cmd.exe', ['/d', '/s', '/c', command],
        stdoutEncoding: null, stderrEncoding: null);
    expect(result.exitCode, 0,
        reason: utf8.decode(result.stderr as List<int>, allowMalformed: true));
    expect(utf8.decode(result.stdout as List<int>), value);
  }, skip: !Platform.isWindows);

  test('Windows proxy relay preserves binary stdin/stdout and exit status',
      () async {
    const echo =
        r'[Console]::OpenStandardInput().CopyTo([Console]::OpenStandardOutput());exit 7';
    final encodedEcho = base64Encode([
      for (final unit in echo.codeUnits) ...[unit & 255, unit >> 8]
    ]);
    final echoCommand =
        'powershell.exe -NoProfile -NonInteractive -EncodedCommand $encodedEcho';
    final args =
        echoCommand.split(' ').skip(1).map(powershellLiteral).join(',');
    final script = r"$codexExecutable = (Get-Command powershell.exe).Source"
        '\n'
        r'$codexPrefix = @()'
        '\n'
        '\$codexArguments = @($args)\n'
        '$windowsProcessRelayScript';
    final command = powershellCommand(script);
    expect(command.length, lessThan(8191));
    final bytes = List.generate(128 * 1024, (i) => i % 256);
    final temp = await Directory.systemTemp.createTemp('windows-relay.');
    try {
      final input = File('${temp.path}/input.bin');
      await input.writeAsBytes(bytes);
      // Use a finite OS input handle; Dart's Windows subprocess pipe can keep
      // an inherited writer alive across nested processes after stdin.close.
      final result = await Process.run(
              'cmd.exe', ['/d', '/s', '/c', '$command < input.bin'],
              workingDirectory: temp.path,
              stdoutEncoding: null,
              stderrEncoding: null)
          .timeout(const Duration(seconds: 20));
      expect(result.exitCode, 7,
          reason:
              utf8.decode(result.stderr as List<int>, allowMalformed: true));
      expect(result.stdout, bytes);
    } finally {
      await temp.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);
}

Future<ProcessResult> _run(String command) =>
    Process.run('powershell.exe', command.split(' ').skip(1).toList(),
        stdoutEncoding: utf8,
        stderrEncoding: const Utf8Codec(allowMalformed: true));

String _inDirectory(String command, String directory) {
  final bytes = base64Decode(command.split(' ').last);
  final wrapper = String.fromCharCodes([
    for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8),
  ]);
  final payload = RegExp(r'FromBase64String\("([A-Za-z0-9+/=]+)"\)')
      .firstMatch(wrapper)!
      .group(1)!;
  final script = utf8.decode(gzip.decode(base64Decode(payload)));
  return powershellCommand(script.replaceFirst(
      "([Environment]::GetFolderPath('LocalApplicationData'))",
      powershellLiteral(directory)));
}
