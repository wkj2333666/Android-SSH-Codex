import 'package:android_ssh_codex/src/profiles/host_profile.dart';
import 'package:android_ssh_codex/src/ui/profile_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ProxyJump profiles expose independent credentials', (
    tester,
  ) async {
    final profile = HostProfile(
      id: 'private',
      label: 'Private host',
      hostName: '10.0.0.8',
      user: 'codex',
      port: 22,
      proxyJump: JumpHostProfile(
        hostName: 'edge.example',
        user: 'jump',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileEditor(profile: profile, secret: const HostSecret()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Jump password'), findsOneWidget);
    expect(find.text('Jump OpenSSH private key'), findsOneWidget);
    expect(find.text('Jump key passphrase'), findsOneWidget);
  });
}
