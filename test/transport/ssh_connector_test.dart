import 'package:android_ssh_codex/src/transport/ssh_connector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes empty private key passphrases to null', () {
    expect(normalizePrivateKeyPassphrase(''), isNull);
    expect(normalizePrivateKeyPassphrase('   '), isNull);
  });

  test('preserves non-empty private key passphrases exactly', () {
    expect(normalizePrivateKeyPassphrase('  secret  '), '  secret  ');
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
