import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../diagnostics.dart';
import '../profiles/host_profile.dart';
import '../profiles/profile_store.dart';
import 'ssh_health_monitor.dart';

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

typedef PrivateKeyParser = List<SSHKeyPair> Function(
  String privateKey,
  String? passphrase,
);

List<SSHKeyPair>? parsePrivateKeyIdentities(
  String? privateKey,
  String? passphrase, {
  PrivateKeyParser parser = SSHKeyPair.fromPem,
}) {
  if (privateKey == null || privateKey.trim().isEmpty) return null;
  return parser(privateKey, normalizePrivateKeyPassphrase(passphrase));
}

typedef HostKeyPrompt = Future<bool> Function(HostKeyChallenge challenge);

final _sshDiagnostics = Expando<_SshDiagnostic>();
final _sshHealth = Expando<SshHealthMonitor>();
int _nextSshDiagnosticId = 0;

final class _SshDiagnostic {
  _SshDiagnostic(this.role, this.attempt);
  final String role;
  final int? attempt;
  final int id = ++_nextSshDiagnosticId;
  final watch = Stopwatch()..start();
  bool localClose = false;
  Map<String, Object?> get fields => {
        'ssh': id,
        'role': role,
        'attempt': attempt,
        'ageMs': watch.elapsedMilliseconds,
        'localCloseRequested': localClose,
      };
}

void _requestSshClose(SSHClient client, String reason) {
  _sshHealth[client]?.dispose();
  final diagnostic = _sshDiagnostics[client];
  if (diagnostic != null) diagnostic.localClose = true;
  Diagnostics.record('ssh.closeRequested', {
    ...?diagnostic?.fields,
    'closeReason': reason,
  });
  client.close();
}

final class SshConnection {
  const SshConnection({required this.client, this.jumpClient});

  final SSHClient client;
  final SSHClient? jumpClient;

  Future<bool> checkHealth() async =>
      await _sshHealth[client]?.check() ?? !client.isClosed;

  Future<void> close({String reason = 'transport_cleanup'}) async {
    _requestSshClose(client, reason);
    await client.done.catchError((_) {});
    if (jumpClient != null) _requestSshClose(jumpClient!, reason);
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
    int? diagnosticAttempt,
    String diagnosticRole = 'target',
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
          diagnostic: _SshDiagnostic('jump', diagnosticAttempt),
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
        diagnostic: _SshDiagnostic(diagnosticRole, diagnosticAttempt),
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
    required _SshDiagnostic diagnostic,
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
    final identities = parsePrivateKeyIdentities(privateKey, passphrase);
    final client = SSHClient(
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
      keepAliveInterval: null,
      handshakeTimeout: const Duration(seconds: 15),
      authTimeout: const Duration(seconds: 20),
      ident: 'AndroidSSHCodex_0.1',
    );
    _sshDiagnostics[client] = diagnostic;
    final health = SshHealthMonitor(ping: client.ping, onFailure: (error) {
      Diagnostics.record('ssh.health.error', {
        ...diagnostic.fields,
        'stage': 'keepalive_reply',
        ...Diagnostics.errorFields(error),
      });
      _requestSshClose(client, 'ssh_health_check_failed');
    });
    _sshHealth[client] = health;
    unawaited(client.authenticated.then((_) => health.start(),
        onError: (Object _) {}));
    Diagnostics.record('ssh.open', diagnostic.fields);
    unawaited(client.done.then((_) {
      health.dispose();
      Diagnostics.record('ssh.done', {
        ...diagnostic.fields,
        'reason': diagnostic.localClose ? 'local_close' : 'eof_without_reason',
      });
    }, onError: (Object error, StackTrace stackTrace) {
      health.dispose();
      Diagnostics.record('ssh.error', {
        ...diagnostic.fields,
        ...Diagnostics.errorFields(error),
      });
    }));
    return client;
  }
}

Future<void> _closeClient(SSHClient? client) async {
  if (client == null) return;
  _requestSshClose(client, 'connection_setup_failed');
  await client.done.catchError((_) {});
}
