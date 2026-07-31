import 'dart:async';
import 'dart:typed_data';

import 'package:android_ssh_codex/main.dart' as application;
import 'package:android_ssh_codex/src/app.dart';
import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/profiles/host_profile.dart';
import 'package:android_ssh_codex/src/profiles/profile_store.dart';
import 'package:android_ssh_codex/src/transport/codex_daemon.dart';
import 'package:android_ssh_codex/src/transport/ssh_connector.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  test('connection bootstrap applies the selected profile environment',
      () async {
    final store = MemoryProfileStore();
    final profile = HostProfile(
      id: 'raspberry-pi',
      label: 'Raspberry Pi',
      hostName: 'pi.example.test',
      user: 'pi',
      port: 22,
      environment: const {
        'LC_CODEX_BACKEND': 'sub2api',
        'CODEX_TOKEN': 'secret-value',
      },
    );
    await store.writeProfile(profile, const HostSecret(password: 'password'));
    final client = _RecordingSshClient();
    final controller = AppController(
      store: store,
      connect: (profile, secret, {required prompt}) async =>
          SshConnection(client: client),
    );

    await controller.connectHost(profile);

    expect(client.commands, [CodexDaemon.bootstrapScript]);
    expect(client.environments, [profile.environment]);
    expect(
      controller.error,
      'Remote Codex app-server did not report its socket.',
    );
  });
}

final class _RecordingSshClient implements SSHClient {
  final List<String> commands = [];
  final List<Map<String, String>?> environments = [];

  @override
  Future<Uint8List> run(
    String command, {
    bool runInPty = false,
    bool stdout = true,
    bool stderr = true,
    Map<String, String>? environment,
  }) async {
    commands.add(command);
    environments.add(environment);
    return Uint8List(0);
  }

  @override
  void close() {}

  @override
  Future<void> get done async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
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
}
