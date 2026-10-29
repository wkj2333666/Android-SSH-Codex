import 'dart:io';

import 'package:android_ssh_codex/src/profiles/host_profile.dart';
import 'package:android_ssh_codex/src/profiles/profile_store.dart';
import 'package:android_ssh_codex/src/profiles/secure_key_value_store.dart';
import 'package:android_ssh_codex/src/transport/ssh_connector.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Storage implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

HostProfile _profile(String jump) => HostProfile(
    id: 'private',
    label: 'Private',
    hostName: '127.0.0.1',
    port: 22229,
    user: 'coder',
    proxyJump: JumpHostProfile(hostName: jump, user: 'gateway'));

void main() {
  for (final secure in [false, true]) {
    test('jump endpoint edits reset only its host pin (secure: $secure)',
        () async {
      final ProfileStore store =
          secure ? SecureProfileStore(_Storage()) : MemoryProfileStore();
      await store.writeProfile(_profile('edge-a'), const HostSecret());
      await store.writeHostFingerprint('private', 'target-pin');
      await store.writeHostFingerprint('private.jump', 'jump-pin');
      await store.writeProfile(_profile('edge-a'), const HostSecret());
      expect(await store.readHostFingerprint('private.jump'), 'jump-pin');
      await store.writeProfile(_profile('edge-b'), const HostSecret());
      expect(await store.readHostFingerprint('private.jump'), isNull);
      expect(await store.readHostFingerprint('private'), 'target-pin');
      await store.writeHostFingerprint('private.jump', 'replacement-pin');
      await store.deleteProfile('private');
      expect(await store.readHostFingerprint('private.jump'), isNull);
    });
  }

  test('options keep safe legacy defaults and reject invalid stored ranges',
      () {
    final options = SshConnectionOptions.fromJson({
      'connectTimeoutSeconds': -1,
      'authTimeoutSeconds': 0,
      'keepAliveIntervalSeconds': 99999
    });
    expect(options, const SshConnectionOptions());
    expect(options.setupTimeout(hasJumpHost: true),
        greaterThan(options.setupTimeout(hasJumpHost: false)));
    expect(
        const SshConnectionOptions(keepAliveIntervalSeconds: 0)
            .keepAliveInterval,
        Duration.zero);
  });

  test('real SSH jump authenticates and pins both hosts, then closes both',
      () async {
    final key =
        await File(Platform.environment['DOWNLOAD_TEST_KEY']!).readAsString();
    final user = Platform.environment['USER']!;
    final profile = _profile('127.0.0.1').copyWith(
        user: user,
        proxyJump:
            JumpHostProfile(hostName: '127.0.0.1', port: 22229, user: user),
        sshOptions: const SshConnectionOptions(
            connectTimeoutSeconds: 10,
            authTimeoutSeconds: 10,
            keepAliveIntervalSeconds: 0));
    final secret = HostSecret(privateKey: key, jumpPrivateKey: key);
    final store = MemoryProfileStore();
    var prompts = 0;
    final connector = SshConnector(store);
    for (var attempt = 0; attempt < 2; attempt++) {
      final connection =
          await connector.connect(profile, secret, prompt: (_) async {
        prompts++;
        return true;
      });
      try {
        expect(connection.jumpClient, isNotNull);
        expect(await connection.checkHealth(), isTrue);
        await connection.jumpClient!.ping();
        expect(await store.readHostFingerprint('private'), isNotNull);
        expect(await store.readHostFingerprint('private.jump'), isNotNull);
      } finally {
        await connection.close();
      }
      expect(connection.client.isClosed, isTrue);
      expect(connection.jumpClient!.isClosed, isTrue);
    }
    expect(prompts, 2);
  }, skip: !Platform.environment.containsKey('DOWNLOAD_TEST_KEY'));
}
