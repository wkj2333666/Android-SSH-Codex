import 'package:android_ssh_codex/src/transport/ssh_connector.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes empty private key passphrases to null', () {
    expect(normalizePrivateKeyPassphrase(null), isNull);
    expect(normalizePrivateKeyPassphrase(''), isNull);
    expect(normalizePrivateKeyPassphrase('   '), isNull);
  });

  test('preserves non-empty private key passphrases exactly', () {
    expect(normalizePrivateKeyPassphrase('  secret  '), '  secret  ');
  });

  test('passes null for an empty target key passphrase', () {
    final recorder = _PrivateKeyParserRecorder();
    final PrivateKeyParser fakeParser = recorder.call;

    final identities = parsePrivateKeyIdentities(
      'target-key',
      '',
      parser: fakeParser,
    );

    expect(identities, same(recorder.identities));
    expect(recorder.privateKey, 'target-key');
    expect(recorder.passphrase, isNull);
    expect(recorder.calls, 1);
  });

  test('passes null for a whitespace-only jump key passphrase', () {
    final recorder = _PrivateKeyParserRecorder();
    final PrivateKeyParser fakeParser = recorder.call;

    parsePrivateKeyIdentities('jump-key', '   ', parser: fakeParser);

    expect(recorder.privateKey, 'jump-key');
    expect(recorder.passphrase, isNull);
    expect(recorder.calls, 1);
  });

  test('preserves a non-empty parser passphrase exactly', () {
    final recorder = _PrivateKeyParserRecorder();
    final PrivateKeyParser fakeParser = recorder.call;

    parsePrivateKeyIdentities(
      'encrypted-key',
      '  secret  ',
      parser: fakeParser,
    );

    expect(recorder.passphrase, '  secret  ');
    expect(recorder.calls, 1);
  });

  test('skips parsing blank and null private keys', () {
    final recorder = _PrivateKeyParserRecorder();
    final PrivateKeyParser fakeParser = recorder.call;

    expect(parsePrivateKeyIdentities('', null, parser: fakeParser), isNull);
    expect(parsePrivateKeyIdentities(null, null, parser: fakeParser), isNull);
    expect(recorder.calls, 0);
  });

  test('formats host keys as standard SHA256 base64 fingerprints', () {
    expect(
      formatHostKeyFingerprint(List.filled(32, 0)),
      'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    );
  });

  test('host key mismatch explains the explicit recovery path', () {
    const error = HostKeyMismatchException(
      'Build host',
      'SHA256:expected',
      'SHA256:actual',
    );

    expect(error.toString(), contains('Host key mismatch'));
    expect(error.toString(), contains('Delete and recreate'));
  });
}

final class _PrivateKeyParserRecorder {
  final identities = <SSHKeyPair>[];
  var calls = 0;
  String? privateKey;
  String? passphrase;

  List<SSHKeyPair> call(String privateKey, String? passphrase) {
    calls++;
    this.privateKey = privateKey;
    this.passphrase = passphrase;
    return identities;
  }
}
