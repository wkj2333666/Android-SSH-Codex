import 'dart:convert';
import 'dart:io';

import 'package:android_ssh_codex/src/transport/codex_daemon.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory fixture;
  late String userHome;
  late String initialPath;

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('codex-path-');
    userHome = '${fixture.path}/user home with\'quote';
    initialPath = '${fixture.path}/tools';
    await Directory(userHome).create();
    await Directory(initialPath).create();
    await Link('$initialPath/base64').create('/usr/bin/base64');
  });

  tearDown(() => fixture.delete(recursive: true));

  Future<void> executable(String directory, String body,
      {String name = 'codex'}) async {
    await Directory(directory).create(recursive: true);
    final file = File('$directory/$name');
    await file.writeAsString('#!/bin/sh\n$body\n');
    final chmod = await Process.run('chmod', ['700', file.path]);
    expect(chmod.exitCode, 0);
  }

  Future<ProcessResult> run(String command,
          {Map<String, String> extra = const {}}) =>
      Process.run('/bin/sh', ['-c', command],
          includeParentEnvironment: false,
          environment: {'HOME': userHome, 'PATH': initialPath, ...extra});

  test('shared startup finds local bin with spaces and quotes in home',
      () async {
    await executable('$userHome/.local/bin', r'''printf '%s\n' "$*"''');
    final result = await run(CodexDaemon.sharedStartCommand);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stdout, 'app-server daemon start\n');
    expect(result.stderr, isEmpty);
  });

  test('an existing PATH selection wins over fallback installations', () async {
    await File('$userHome/.bashrc').writeAsString('echo unwanted; exit 99\n');
    await executable(initialPath, "printf '%s\\n' selected");
    await executable('$userHome/.local/bin', 'exit 99');
    await executable(
        '$userHome/.local/lib/codex-provider-switcher/bin', 'exit 98');
    final result = await run(CodexDaemon.sharedStartCommand);
    expect(result.exitCode, 0);
    expect(result.stdout, 'selected\n');
  });

  test('fallback preserves a provider wrapper before a raw local binary',
      () async {
    await executable('$userHome/.local/bin', 'exit 99');
    await executable('$userHome/.local/lib/codex-provider-switcher/bin',
        "printf '%s\\n' wrapper");
    final result = await run(CodexDaemon.sharedStartCommand);
    expect(result.exitCode, 0);
    expect(result.stdout, 'wrapper\n');
  });

  test('fallback exports directories for launcher dependencies', () async {
    await executable('$userHome/.npm-global/bin', 'exec codex-test-helper');
    await executable('$userHome/.local/bin', "printf '%s\\n' dependency",
        name: 'codex-test-helper');
    final result = await run(CodexDaemon.sharedStartCommand);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stdout, 'dependency\n');
  });

  test('explicit install directory supports a custom installation', () async {
    final install = '${fixture.path}/custom bin';
    await executable(install, "printf '%s\\n' custom");
    final result = await run(CodexDaemon.sharedStartCommand,
        extra: {'CODEX_INSTALL_DIR': install});
    expect(result.exitCode, 0);
    expect(result.stdout, 'custom\n');
  });

  test('interactive bashrc PATH and launcher dependencies are imported',
      () async {
    await executable('$userHome/managed bin', 'exec codex-test-helper');
    await executable('$userHome/managed bin', "printf '%s\\n' from-bashrc",
        name: 'codex-test-helper');
    await File('$userHome/.bashrc').writeAsString(r'''
case $- in *i*) ;; *) return ;; esac
printf 'startup noise\n'
printf 'startup stderr\n' >&2
export PATH="$HOME/managed bin:$PATH"
''');
    final result = await run(CodexDaemon.sharedStartCommand);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stdout, 'from-bashrc\n');
    expect(result.stderr, isEmpty);
  });

  test('bashrc selection precedes guessed installation directories', () async {
    await executable('$userHome/managed bin', "printf '%s\\n' managed");
    await executable('$userHome/.local/bin', 'exit 99');
    await File('$userHome/.bashrc')
        .writeAsString('export PATH="\$HOME/managed bin:\$PATH"\n');
    final result = await run(CodexDaemon.sharedStartCommand);
    expect(result.exitCode, 0);
    expect(result.stdout, 'managed\n');
  });

  test('alias and function are not mistaken for executable paths', () async {
    await executable('$userHome/.local/bin', "printf '%s\\n' fallback");
    await File('$userHome/.bashrc').writeAsString(r'''
codex() { echo function-output; }
alias codex='echo alias-output'
''');
    final result = await run(CodexDaemon.sharedStartCommand);
    expect(result.exitCode, 0);
    expect(result.stdout, 'fallback\n');
  });

  test('blocking bashrc is bounded and falls back with a diagnostic', () async {
    await executable('$userHome/.local/bin', "printf '%s\\n' fallback");
    await File('$userHome/.bashrc').writeAsString('exec /bin/sleep 30\n');
    final result = await run(CodexDaemon.sharedStartCommand)
        .timeout(const Duration(seconds: 10));
    expect(result.exitCode, 0);
    expect(result.stdout, 'fallback\n');
    expect(result.stderr, contains('bashrc PATH probe timed out'));
  });

  test('early bashrc exit leaves existing fallback usable', () async {
    await executable('$userHome/.local/bin', "printf '%s\\n' fallback");
    await File('$userHome/.bashrc').writeAsString('exit 0\n');
    final result = await run(CodexDaemon.sharedStartCommand);
    expect(result.exitCode, 0);
    expect(result.stdout, 'fallback\n');
  });

  test(
      'missing or non-executable Codex fails clearly without shell startup files',
      () async {
    await File('$userHome/.profile').writeAsString('exit 99\n');
    await Directory('$userHome/.local/bin').create(recursive: true);
    await File('$userHome/.local/bin/codex').writeAsString('not executable');
    final result = await run(CodexDaemon.sharedStartCommand);
    expect(result.exitCode, 127);
    expect(result.stdout, isEmpty);
    expect(result.stderr, contains('codex executable not found in SSH PATH'));
    expect(result.stderr, isNot(contains(userHome)));
  });

  test('bashrc probe does not consume downstream proxy stdin', () async {
    await File('$userHome/.bashrc').writeAsString(r'''
read -r ignored
printf 'startup noise\n'
export PATH="$HOME/managed bin:$PATH"
''');
    await executable('$userHome/managed bin', r'''
IFS= read -r line || exit 3
printf 'socket=%s\ninput=%s\n' "$4" "$line"
''');
    final process = await Process.start(
        '/bin/sh', ['-c', CodexDaemon.proxyCommand("/tmp/socket with'quote")],
        includeParentEnvironment: false,
        environment: {'HOME': userHome, 'PATH': initialPath});
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    process.stdin.writeln('GET / HTTP/1.1');
    await process.stdin.close();
    expect(await process.exitCode.timeout(const Duration(seconds: 5)), 0,
        reason: await errors);
    expect(
        await output, "socket=/tmp/socket with'quote\ninput=GET / HTTP/1.1\n");
  });

  test('isolated bootstrap resolves Codex before any lifecycle mutations', () {
    final command = CodexDaemon.bootstrapCommand(const {});
    final payload =
        RegExp("'([A-Za-z0-9+/=]+)' ").allMatches(command).last.group(1)!;
    final script = utf8.decode(base64Decode(payload));
    expect(script.indexOf('command -v codex'),
        lessThan(script.indexOf('mkdir -p')));
    expect(script, contains(r'nohup "$codex_executable" app-server'));
  });
}
