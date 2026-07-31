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
      proxyJump: const JumpHostProfile(
        hostName: 'edge.example',
        user: 'jump',
      ),
    );

    await _openEditor(tester, profile: profile);

    expect(find.text('Jump password'), findsOneWidget);
    expect(find.text('Jump OpenSSH private key'), findsOneWidget);
    expect(find.text('Jump key passphrase'), findsOneWidget);
  });

  testWidgets('existing environment is rendered as sorted assignments', (
    tester,
  ) async {
    final profile = _profile(
      environment: const {
        'Z_LAST': 'last',
        'LC_CODEX_BACKEND': 'sub2api',
      },
    );

    await _openEditor(tester, profile: profile);

    expect(find.text('Advanced SSH'), findsOneWidget);
    await _openAdvancedSsh(tester);
    expect(
      _textField(tester, 'Environment variables').controller!.text,
      'LC_CODEX_BACKEND=sub2api\nZ_LAST=last',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('SSH config import fills the environment field', (tester) async {
    await _openEditor(tester);
    await tester.tap(find.text('Import SSH config'));
    await tester.pumpAndSettle();
    await tester.enterText(
      _fieldFinder('~/.ssh/config contents'),
      '''
Host pi
  HostName 192.0.2.10
  User codex
  SetEnv Z_LAST=last LC_CODEX_BACKEND=sub2api
''',
    );
    await tester.enterText(_fieldFinder('Host alias'), 'pi');
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();

    await _openAdvancedSsh(tester);
    expect(
      _textField(tester, 'Environment variables').controller!.text,
      'LC_CODEX_BACKEND=sub2api\nZ_LAST=last',
    );
  });

  testWidgets('missing equals blocks Save with a safe line-specific error', (
    tester,
  ) async {
    final result = await _openEditor(tester, profile: _profile());
    await _openAdvancedSsh(tester);
    await tester.enterText(
      _fieldFinder('Environment variables'),
      'VALID=ok\nsecret-value',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Invalid environment assignment on line 2: '
        'Environment assignment must contain an equals sign.',
      ),
      findsOneWidget,
    );
    expect(result(), isNull);
  });

  testWidgets('duplicate environment names block Save', (tester) async {
    final result = await _openEditor(tester, profile: _profile());
    await _openAdvancedSsh(tester);
    await tester.enterText(
      _fieldFinder('Environment variables'),
      'TOKEN=first-secret\nTOKEN=second-secret',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(
      find.text('Duplicate environment variable TOKEN on line 2.'),
      findsOneWidget,
    );
    expect(result(), isNull);
  });

  testWidgets('valid Save returns the parsed environment map', (tester) async {
    final result = await _openEditor(tester, profile: _profile());
    await _openAdvancedSsh(tester);
    await tester.enterText(
      _fieldFinder('Environment variables'),
      'LC_CODEX_BACKEND=sub2api\nTOKEN=a=b',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(result(), isNotNull);
    expect(result()!.profile.environment, {
      'LC_CODEX_BACKEND': 'sub2api',
      'TOKEN': 'a=b',
    });
  });
}

HostProfile _profile({Map<String, String> environment = const {}}) =>
    HostProfile(
      id: 'pi',
      label: 'Raspberry Pi',
      hostName: '192.0.2.10',
      user: 'codex',
      port: 22,
      environment: environment,
    );

Future<ProfileDraft? Function()> _openEditor(
  WidgetTester tester, {
  HostProfile? profile,
}) async {
  ProfileDraft? result;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () async {
              result = await showDialog<ProfileDraft>(
                context: context,
                builder: (_) => ProfileEditor(
                  profile: profile,
                  secret: const HostSecret(),
                ),
              );
            },
            child: const Text('Open editor'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open editor'));
  await tester.pumpAndSettle();
  return () => result;
}

Future<void> _openAdvancedSsh(WidgetTester tester) async {
  final advanced = find.text('Advanced SSH');
  await tester.scrollUntilVisible(
    advanced,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(advanced);
  await tester.pumpAndSettle();
}

Finder _fieldFinder(String label) => find.byWidgetPredicate(
      (widget) =>
          widget is TextFormField && widget.decoration?.labelText == label,
    );

TextFormField _textField(WidgetTester tester, String label) =>
    tester.widget<TextFormField>(_fieldFinder(label));
