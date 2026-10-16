import 'dart:convert';
import 'dart:io';

import 'package:android_ssh_codex/src/transport/codex_daemon.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'bootstrap passes the exact environment to the SSH command runner',
    () async {
      final environment = Map<String, String>.unmodifiable({
        'LC_CODEX_BACKEND': 'sub2api',
        'CODEX_LABEL': 'mobile client',
      });
      var calls = 0;
      String? receivedCommand;
      Map<String, String>? receivedEnvironment;

      Future<SshCommandResult> runner(
        String command, {
        Map<String, String>? environment,
      }) async {
        calls++;
        receivedCommand = command;
        receivedEnvironment = environment;
        return _result(
          stdout: '/home/codex/.cache/android-ssh-codex/app-server.sock\n',
        );
      }

      final socketPath = await CodexDaemon.bootstrap(
        runner,
        environment: environment,
      );

      expect(calls, 1);
      expect(receivedCommand, CodexDaemon.bootstrapCommand(environment));
      final match = RegExp(
        r"^printf '%s' '([A-Za-z0-9+/=]+)' \| base64 -d \| /bin/sh$",
      ).firstMatch(receivedCommand!);
      expect(match, isNotNull);
      final script = utf8.decode(base64Decode(match!.group(1)!));
      expect(script, contains(CodexDaemon.bootstrapScript));
      expect(script, isNot(contains('sub2api')));
      expect(script, isNot(contains('mobile client')));
      expect(identical(receivedEnvironment, environment), isTrue);
      expect(
        socketPath,
        '/home/codex/.cache/android-ssh-codex/app-server.sock',
      );
    },
  );

  test('environment fingerprint is stable and sensitive to map contents', () {
    final first = CodexDaemon.environmentFingerprint(const {
      'Z_LAST': 'last',
      'LC_CODEX_BACKEND': 'sub2api',
    });
    final reordered = CodexDaemon.environmentFingerprint(const {
      'LC_CODEX_BACKEND': 'sub2api',
      'Z_LAST': 'last',
    });
    final changed = CodexDaemon.environmentFingerprint(const {
      'LC_CODEX_BACKEND': 'other',
      'Z_LAST': 'last',
    });

    expect(first, reordered);
    expect(changed, isNot(first));
    expect(first, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test('proxy command preserves SSH stdin for the downstream proxy', () async {
    final directory = await Directory.systemTemp.createTemp(
      'codex-proxy-test.',
    );
    try {
      final fakeCodex = File('${directory.path}/codex');
      await fakeCodex.writeAsString(r'''#!/bin/sh
if [ "$#" -ne 4 ] || [ "$1" != app-server ] || [ "$2" != proxy ] || [ "$3" != --sock ]; then
  printf '%s\n' "unexpected arguments: $*" >&2
  exit 2
fi
if ! IFS= read -r line; then
  printf '%s\n' 'downstream received EOF before the WebSocket upgrade' >&2
  exit 3
fi
printf 'socket=%s\nstdin=%s\n' "$4" "$line"
''');
      final chmod = await Process.run('chmod', ['700', fakeCodex.path]);
      expect(chmod.exitCode, 0, reason: chmod.stderr.toString());

      final command = CodexDaemon.proxyCommand("/home/cod'ex/app.sock");
      final process = await Process.start(
        '/bin/sh',
        ['-c', command],
        environment: {
          ...Platform.environment,
          'PATH': '${directory.path}:${Platform.environment['PATH'] ?? ''}',
        },
      );
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      process.stdin.writeln('websocket-upgrade');
      await process.stdin.close();

      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 5),
      );
      final output = await stdout;
      final diagnostic = await stderr;

      expect(exitCode, 0, reason: diagnostic);
      expect(
        output,
        "socket=/home/cod'ex/app.sock\nstdin=websocket-upgrade\n",
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('shared mode parses the daemon lifecycle socket and forwards env',
      () async {
    const environment = {'LC_CODEX_BACKEND': 'sub2api'};
    String? receivedCommand;
    Map<String, String>? receivedEnvironment;

    final socket = await CodexDaemon.startShared(
      (command, {environment}) async {
        receivedCommand = command;
        receivedEnvironment = environment;
        return _result(
          stdout: '{"backend":"pid","socketPath":'
              '"/home/codex/.codex/app-server-control/'
              'app-server-control.sock","cliVersion":"0.146.0",'
              '"started":true}\n',
          stderr: 'non-fatal warning\n',
        );
      },
      environment: environment,
    );

    expect(
      _decodeShellWrapper(receivedCommand!),
      contains(r'exec "$codex_executable" app-server daemon start'),
    );
    expect(identical(receivedEnvironment, environment), isTrue);
    expect(
      socket,
      '/home/codex/.codex/app-server-control/app-server-control.sock',
    );
  });

  for (final invalid in <String, String>{
    'malformed JSON': 'not-json',
    'missing socketPath': '{"backend":"pid"}',
    'relative socketPath': '{"socketPath":"relative.sock"}',
    'control character': '{"socketPath":"/tmp/bad\\n.sock"}',
  }.entries) {
    test('shared mode rejects ${invalid.key}', () async {
      await expectLater(
        CodexDaemon.startShared(
          (command, {environment}) async => _result(stdout: invalid.value),
          environment: const {},
        ),
        throwsA(
          isA<CodexBootstrapException>().having(
            (error) => error.message,
            'message',
            contains('Shared app-server'),
          ),
        ),
      );
    });
  }

  test('shared mode reports daemon failure without isolated bootstrap',
      () async {
    var calls = 0;

    await expectLater(
      CodexDaemon.startShared(
        (command, {environment}) async {
          calls++;
          return _result(
            stderr: 'daemon refused to start',
            exitCode: 1,
          );
        },
        environment: const {},
      ),
      throwsA(
        isA<CodexBootstrapException>()
            .having(
              (error) => error.message,
              'message',
              contains('Shared app-server'),
            )
            .having(
              (error) => error.message,
              'message',
              contains('daemon refused to start'),
            ),
      ),
    );
    expect(calls, 1);
  });

  test('shared mode probes the existing standard socket for an old CLI',
      () async {
    final commands = <String>[];

    final socket = await CodexDaemon.startShared(
      (command, {environment}) async {
        commands.add(_decodeShellWrapper(command));
        if (commands.length == 1) {
          return _result(
            stderr: "error: unrecognized subcommand 'daemon'",
            exitCode: 2,
          );
        }
        return _result(
          stdout: '/home/codex/.codex/app-server-control/'
              'app-server-control.sock\n',
        );
      },
      environment: const {},
    );

    expect(commands, hasLength(2));
    expect(commands.first,
        contains(r'exec "$codex_executable" app-server daemon start'));
    expect(commands.last, contains('app-server-control.sock'));
    expect(commands.last, isNot(contains('android-ssh-codex')));
    expect(
      socket,
      '/home/codex/.codex/app-server-control/app-server-control.sock',
    );
  });

  test('bootstrap omits an empty environment from the SSH request', () async {
    Map<String, String>? receivedEnvironment = const {'unexpected': 'value'};

    await CodexDaemon.bootstrap(
      (command, {environment}) async {
        receivedEnvironment = environment;
        return _result(
          stdout: '/home/codex/.cache/android-ssh-codex/app-server.sock\n',
        );
      },
      environment: const {},
    );

    expect(receivedEnvironment, isNull);
  });

  test('bootstrap reports a nonzero remote exit with stderr', () async {
    await expectLater(
      CodexDaemon.bootstrap(
        (command, {environment}) async => _result(
          stderr: '/bin/sh: codex: not found\n',
          exitCode: 127,
        ),
        environment: const {},
      ),
      throwsA(
        isA<CodexBootstrapException>()
            .having(
              (error) => error.message,
              'message',
              contains('exit code 127'),
            )
            .having(
              (error) => error.message,
              'message',
              contains('codex: not found'),
            ),
      ),
    );
  });

  test('bootstrap reports a remote exit signal', () async {
    await expectLater(
      CodexDaemon.bootstrap(
        (command, {environment}) async => _result(
          stderr: 'terminated remotely',
          exitCode: null,
          exitSignal: 'KILL',
        ),
        environment: const {},
      ),
      throwsA(
        isA<CodexBootstrapException>().having(
          (error) => error.message,
          'message',
          contains('signal KILL'),
        ),
      ),
    );
  });

  test(
    'bootstrap reports diagnostic output when the socket is absent',
    () async {
      await expectLater(
        CodexDaemon.bootstrap(
          (command, {environment}) async => _result(
            stderr: 'socket was not created',
          ),
          environment: const {},
        ),
        throwsA(
          isA<CodexBootstrapException>().having(
            (error) => error.message,
            'message',
            contains('socket was not created'),
          ),
        ),
      );
    },
  );

  test('bootstrap bounds untrusted remote diagnostics', () async {
    Object? thrown;
    try {
      await CodexDaemon.bootstrap(
        (command, {environment}) async => _result(
          stderr: List.filled(5000, 'x').join(),
          exitCode: 1,
        ),
        environment: const {},
      );
    } catch (error) {
      thrown = error;
    }

    expect(thrown, isA<CodexBootstrapException>());
    expect(thrown.toString().length, lessThan(1400));
    expect(thrown.toString(), endsWith('...'));
  });

  test(
    'bootstrap explains server environment rejection without leaking value',
    () async {
      const value = 'top-secret-value';

      await expectLater(
        CodexDaemon.bootstrap(
          (command, {environment}) async {
            throw SSHChannelRequestError(
              'Failed to set environment variable: SECRET_NAME',
            );
          },
          environment: const {'SECRET_NAME': value},
        ),
        throwsA(
          isA<StateError>()
              .having(
                (error) => error.message,
                'message',
                contains('SECRET_NAME'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('AcceptEnv'),
              )
              .having(
                (error) => error.message,
                'message',
                isNot(contains(value)),
              ),
        ),
      );
    },
  );

  test(
    'bootstrap propagates unrelated channel request errors unchanged',
    () async {
      final rejection = SSHChannelRequestError('Failed to execute');

      try {
        await CodexDaemon.bootstrap(
          (command, {environment}) async => throw rejection,
          environment: const {'MODE': 'review'},
        );
        fail('Expected the runner to fail.');
      } catch (error) {
        expect(identical(error, rejection), isTrue);
      }
    },
  );

  test('bootstrap is namespaced and locks daemon lifecycle changes', () {
    const script = CodexDaemon.bootstrapScript;

    expect(script, contains('android-ssh-codex'));
    expect(script, contains(r'mkdir "$lock"'));
    expect(script, contains(r'app-server --listen "unix://$socket"'));
    expect(script, isNot(contains('pkill')));
    expect(script, isNot(contains('killall')));
    expect(script, isNot(contains('.codex/app-server.sock')));
  });

  test(
    'bootstrap restarts only a verified daemon after an environment change',
    () {
      const script = CodexDaemon.bootstrapScript;

      final lockAcquisition = script.indexOf('while ! mkdir');
      final processValidation = script.indexOf('is_our_server_running()');
      final fingerprintCheck =
          script.indexOf('environment_fingerprint_matches');
      final termination = script.indexOf('kill ');

      expect(processValidation, greaterThanOrEqualTo(0));
      expect(fingerprintCheck, greaterThan(processValidation));
      expect(termination, greaterThan(lockAcquisition));
      expect(termination, greaterThan(fingerprintCheck));
      expect(
        script,
        contains('The existing Codex app-server uses a different environment'),
      );
    },
  );

  test(
    'bootstrap persists an environment fingerprint rather than raw values',
    () {
      const script = CodexDaemon.bootstrapScript;

      expect(script, contains('environment-fingerprint'));
      expect(script, contains('environment_fingerprint'));
      expect(script, isNot(contains('LC_CODEX_BACKEND')));
      expect(script, isNot(contains('sub2api')));
    },
  );

  test('bootstrap only removes files below its own base directory', () {
    const script = CodexDaemon.bootstrapScript;

    expect(script, contains(r'rm -f "$socket" "$pidfile"'));
    expect(script, isNot(contains('rm -rf')));
    expect(script, isNot(contains(r'\"')));
  });

  test('bootstrap validates its recorded process before reusing a socket', () {
    const script = CodexDaemon.bootstrapScript;

    expect(script, contains(r'pid=$(cat "$pidfile"'));
    expect(script, contains(r'/proc/$pid/cmdline'));
    expect(script, contains('codex app-server'));
    expect(script, contains(r'rm -f "$socket" "$pidfile"'));
  });

  test('bootstrap never removes socket state before owning the startup lock',
      () {
    const script = CodexDaemon.bootstrapScript;

    final lockAcquisition = script.indexOf(r'while ! mkdir "$lock"');
    final firstCleanup = script.indexOf(r'rm -f "$socket" "$pidfile"');

    expect(lockAcquisition, greaterThanOrEqualTo(0));
    expect(firstCleanup, greaterThan(lockAcquisition));
  });

  test('bootstrap never cleans up a live daemon with a missing socket', () {
    const script = CodexDaemon.bootstrapScript;

    final liveFailure = script.indexOf('App-server process is alive');
    final cleanup = script.indexOf(r'rm -f "$socket" "$pidfile"');

    expect(liveFailure, greaterThanOrEqualTo(0));
    expect(cleanup, greaterThan(liveFailure));
  });
}

SshCommandResult _result({
  String stdout = '',
  String stderr = '',
  int? exitCode = 0,
  String? exitSignal,
}) =>
    SshCommandResult(
      stdout: utf8.encode(stdout),
      stderr: utf8.encode(stderr),
      exitCode: exitCode,
      exitSignal: exitSignal,
    );

String _decodeShellWrapper(String command) {
  final match = RegExp(
    r"^printf '%s' '([A-Za-z0-9+/=]+)' \| base64 -d \| /bin/sh$",
  ).firstMatch(command);
  expect(match, isNotNull);
  return utf8.decode(base64Decode(match!.group(1)!));
}
