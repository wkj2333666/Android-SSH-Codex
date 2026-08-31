import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:android_ssh_codex/main.dart' as application;
import 'package:android_ssh_codex/src/app.dart';
import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/profiles/host_profile.dart';
import 'package:android_ssh_codex/src/profiles/profile_store.dart';
import 'package:android_ssh_codex/src/projects/remote_project.dart';
import 'package:android_ssh_codex/src/tasks/task_reducer.dart';
import 'package:android_ssh_codex/src/transport/codex_daemon.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('remote notifications redraw only for visible state changes', () {
    expect(
      hasRemoteNotificationVisibleChange(
        event: null,
        activeTurnChanged: false,
      ),
      isFalse,
    );
    expect(
      hasRemoteNotificationVisibleChange(
        event: const TaskEvent.statusChanged('thread', TaskStatus.running),
        activeTurnChanged: false,
      ),
      isTrue,
    );
    expect(
      hasRemoteNotificationVisibleChange(
        event: null,
        activeTurnChanged: true,
      ),
      isTrue,
    );
  });

  test('an owned thread still resumes when this RPC is not subscribed', () {
    expect(
      requiresThreadResumeForSend(
        owned: true,
        subscribed: false,
      ),
      isTrue,
    );
    expect(
      requiresThreadResumeForSend(
        owned: true,
        subscribed: true,
      ),
      isFalse,
    );
  });

  test('auto-connect selection only accepts the remembered profile', () {
    final profiles = [
      HostProfile(
        id: 'pi',
        label: 'Pi',
        hostName: 'pi.example.test',
        user: 'codex',
        port: 22,
      ),
    ];

    expect(resolveAutoConnectProfile(profiles, 'pi'), profiles.single);
    expect(resolveAutoConnectProfile(profiles, 'missing'), isNull);
    expect(resolveAutoConnectProfile(profiles, null), isNull);
  });

  test('storage failures do not prevent application initialization', () async {
    final controller = AppController(
      store: _ReadProfileStore(
        Future.error(StateError('plugin unavailable')),
      ),
    );

    await controller.initialize();

    expect(controller.profiles, isEmpty);
    expect(controller.error, contains('secure storage'));
  });

  test(
    'application renders before secure storage initialization completes',
    () async {
      final profiles = Completer<List<HostProfile>>();
      AndroidSshCodexApp? renderedApp;
      var initializationCompleted = false;

      final initialization = application.bootstrapApplication(
        _ReadProfileStore(profiles.future),
        (app) => renderedApp = app as AndroidSshCodexApp,
      );
      unawaited(initialization.then((_) => initializationCompleted = true));

      expect(renderedApp, isNotNull);
      expect(initializationCompleted, isFalse);

      profiles.complete(const []);
      await initialization;
      expect(initializationCompleted, isTrue);
    },
  );

  test(
    'isolated profile bootstrap applies the selected profile environment',
    () async {
      final profile = HostProfile(
        id: 'raspberry-pi',
        label: 'Raspberry Pi',
        hostName: 'pi.example.test',
        user: 'pi',
        port: 22,
        appServerMode: AppServerMode.isolated,
        environment: const {
          'LC_CODEX_BACKEND': 'sub2api',
          'CODEX_TOKEN': 'secret-value',
        },
      );
      String? receivedCommand;
      Map<String, String>? receivedEnvironment;

      final socketPath = await resolveCodexSocketForProfile(
        (command, {environment}) async {
          receivedCommand = command;
          receivedEnvironment = environment;
          return SshCommandResult(
            stdout: utf8.encode(
              '/home/pi/.cache/android-ssh-codex/app-server.sock\n',
            ),
            stderr: const [],
            exitCode: 0,
            exitSignal: null,
          );
        },
        profile,
      );

      expect(
        receivedCommand,
        CodexDaemon.bootstrapCommand(profile.environment),
      );
      expect(identical(receivedEnvironment, profile.environment), isTrue);
      expect(
        socketPath,
        '/home/pi/.cache/android-ssh-codex/app-server.sock',
      );
    },
  );

  test('shared profile resolves the daemon-reported control socket', () async {
    final profile = HostProfile(
      id: 'shared',
      label: 'Shared daemon',
      hostName: 'pi.example.test',
      user: 'pi',
      port: 22,
      appServerMode: AppServerMode.shared,
    );

    final socketPath = await resolveCodexSocketForProfile(
      (command, {environment}) async => SshCommandResult(
        stdout: utf8.encode(
          '{"socketPath":"/home/pi/.codex/app-server-control/'
          'app-server-control.sock"}\n',
        ),
        stderr: const [],
        exitCode: 0,
        exitSignal: null,
      ),
      profile,
    );

    expect(
      socketPath,
      '/home/pi/.codex/app-server-control/app-server-control.sock',
    );
  });

  test('custom profile returns its socket without running a command', () async {
    var called = false;
    final profile = HostProfile(
      id: 'custom',
      label: 'Custom daemon',
      hostName: 'pi.example.test',
      user: 'pi',
      port: 22,
      appServerMode: AppServerMode.custom,
      customAppServerSocket: '/run/user/1000/codex.sock',
    );

    final socketPath = await resolveCodexSocketForProfile(
      (command, {environment}) async {
        called = true;
        throw StateError('must not run');
      },
      profile,
    );

    expect(called, isFalse);
    expect(socketPath, '/run/user/1000/codex.sock');
  });

  test('custom profile rejects control characters before trimming', () async {
    var called = false;
    final profile = HostProfile(
      id: 'custom-control',
      label: 'Custom daemon',
      hostName: 'pi.example.test',
      user: 'pi',
      port: 22,
      appServerMode: AppServerMode.custom,
      customAppServerSocket: '/run/user/1000/codex.sock\n',
    );

    await expectLater(
      resolveCodexSocketForProfile(
        (command, {environment}) async {
          called = true;
          throw StateError('must not run');
        },
        profile,
      ),
      throwsA(isA<CodexBootstrapException>()),
    );
    expect(called, isFalse);
  });

  test('connection errors identify the SSH TCP stage and endpoint', () {
    final error = describeConnectionFailure(
      ConnectionStage.ssh,
      const SocketException('Connection refused'),
      HostProfile(
        id: 'lab',
        label: 'Lab',
        hostName: '192.0.2.10',
        user: 'codex',
        port: 2222,
      ),
    );

    expect(error, contains('SSH'));
    expect(error, contains('192.0.2.10:2222'));
    expect(error, contains('Connection refused'));
  });

  test('connection errors distinguish the local Codex tunnel stage', () {
    final error = describeConnectionFailure(
      ConnectionStage.rpcTunnel,
      const SocketException('Connection refused'),
      HostProfile(
        id: 'lab',
        label: 'Lab',
        hostName: '192.0.2.10',
        user: 'codex',
        port: 22,
      ),
    );

    expect(error, contains('Codex tunnel'));
    expect(error, contains('SSH connected successfully'));
  });
}

final class _ReadProfileStore implements ProfileStore {
  const _ReadProfileStore(this.profiles);

  final Future<List<HostProfile>> profiles;

  @override
  Future<List<HostProfile>> readProfiles() => profiles;

  @override
  Future<void> deleteProfile(String id) => throw UnimplementedError();

  @override
  Future<Set<String>> readOwnedThreads(String profileId) =>
      throw UnimplementedError();

  @override
  Future<HostSecret> readSecret(String id) => throw UnimplementedError();

  @override
  Future<String?> readAutoConnectHostId() async => null;

  @override
  Future<void> writeAutoConnectHostId(String? profileId) =>
      throw UnimplementedError();

  @override
  Future<String?> readHostFingerprint(String profileId) =>
      throw UnimplementedError();

  @override
  Future<void> writeHostFingerprint(String profileId, String fingerprint) =>
      throw UnimplementedError();

  @override
  Future<void> writeOwnedThreads(String profileId, Set<String> threadIds) =>
      throw UnimplementedError();

  @override
  Future<void> writeProfile(HostProfile profile, HostSecret secret) =>
      throw UnimplementedError();

  @override
  Future<List<RemoteProject>> readProjects(String hostId) async => const [];

  @override
  Future<void> writeProject(RemoteProject project) =>
      throw UnimplementedError();

  @override
  Future<void> deleteProject(String hostId, String projectId) =>
      throw UnimplementedError();
}
