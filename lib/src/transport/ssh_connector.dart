import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../profiles/host_profile.dart';
import '../profiles/profile_store.dart';

final class HostKeyChallenge {
  const HostKeyChallenge({
    required this.label,
    required this.algorithm,
    required this.fingerprint,
  });

  final String label;
  final String algorithm;
  final String fingerprint;
}

final class HostKeyMismatchException implements Exception {
  const HostKeyMismatchException(this.label, this.expected, this.actual);

  final String label;
  final String expected;
  final String actual;

  @override
  String toString() =>
      'Host key mismatch for $label. Expected $expected but received $actual. '
      'Delete and recreate the host profile to trust a replacement key.';
}

String formatHostKeyFingerprint(List<int> bytes) =>
    'SHA256:${base64Encode(bytes).replaceFirst(RegExp(r'=+$'), '')}';

String? normalizePrivateKeyPassphrase(String? value) =>
    value == null || value.trim().isEmpty ? null : value;

typedef HostKeyPrompt = Future<bool> Function(HostKeyChallenge challenge);

final class SshConnection {
  const SshConnection({required this.client, this.jumpClient});

  final SSHClient client;
  final SSHClient? jumpClient;

  Future<void> close() async {
    client.close();
    await client.done.catchError((_) {});
    jumpClient?.close();
    await jumpClient?.done.catchError((_) {});
  }
}

final class SshConnector {
  const SshConnector(this._store);

  final ProfileStore _store;

  Future<SshConnection> connect(
    HostProfile profile,
    HostSecret secret, {
    required HostKeyPrompt prompt,
  }) async {
    SSHClient? jumpClient;
    SSHClient? targetClient;
    SSHSocket? unownedSocket;
    try {
      final jump = profile.proxyJump;
      if (jump == null) {
        unownedSocket = await SSHSocket.connect(
          profile.hostName,
          profile.port,
          timeout: const Duration(seconds: 15),
        );
      } else {
        unownedSocket = await SSHSocket.connect(
          jump.hostName,
          jump.port,
          timeout: const Duration(seconds: 15),
        );
        jumpClient = _client(
          socket: unownedSocket,
          profileId: '${profile.id}.jump',
          label: '${profile.label} jump host',
          user: jump.user,
          password: secret.jumpPassword,
          privateKey: secret.jumpPrivateKey,
          passphrase: secret.jumpPassphrase,
          prompt: prompt,
        );
        unownedSocket = null;
        await jumpClient.authenticated;
        unownedSocket =
            await jumpClient.forwardLocal(profile.hostName, profile.port);
      }

      targetClient = _client(
        socket: unownedSocket,
        profileId: profile.id,
        label: profile.label,
        user: profile.user,
        password: secret.password,
        privateKey: secret.privateKey,
        passphrase: secret.passphrase,
        prompt: prompt,
      );
      unownedSocket = null;
      await targetClient.authenticated;
      return SshConnection(client: targetClient, jumpClient: jumpClient);
    } catch (_) {
      unownedSocket?.destroy();
      await _closeClient(targetClient);
      await _closeClient(jumpClient);
      rethrow;
    }
  }

  SSHClient _client({
    required SSHSocket socket,
    required String profileId,
    required String label,
    required String user,
    required String? password,
    required String? privateKey,
    required String? passphrase,
    required HostKeyPrompt prompt,
  }) {
    if (user.trim().isEmpty) {
      throw ArgumentError('SSH user is required for $label');
    }
    final identities = privateKey == null || privateKey.trim().isEmpty
        ? null
        : SSHKeyPair.fromPem(
            privateKey,
            normalizePrivateKeyPassphrase(passphrase),
          );
    return SSHClient(
      socket,
      username: user,
      identities: identities,
      onPasswordRequest:
          password == null || password.isEmpty ? null : () => password,
      onVerifyHostKey: (algorithm, fingerprintBytes) async {
        final fingerprint = formatHostKeyFingerprint(fingerprintBytes);
        final previous = await _store.readHostFingerprint(profileId);
        if (previous == fingerprint) return true;
        if (previous != null) {
          throw HostKeyMismatchException(label, previous, fingerprint);
        }
        final accepted = await prompt(HostKeyChallenge(
          label: label,
          algorithm: algorithm,
          fingerprint: fingerprint,
        ));
        if (accepted) {
          await _store.writeHostFingerprint(profileId, fingerprint);
        }
        return accepted;
      },
      keepAliveInterval: const Duration(seconds: 15),
      handshakeTimeout: const Duration(seconds: 15),
      authTimeout: const Duration(seconds: 20),
      ident: 'AndroidSSHCodex_0.1',
    );
  }
}

Future<void> _closeClient(SSHClient? client) async {
  if (client == null) return;
  client.close();
  await client.done.catchError((_) {});
}
