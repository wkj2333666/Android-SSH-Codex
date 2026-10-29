import 'package:android_ssh_codex/src/profiles/host_profile.dart';
import 'package:android_ssh_codex/src/ui/profile_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('advanced SSH manually adds a jump host and credentials',
      (tester) async {
    final result = await _openEditor(tester, profile: _profile());
    await _openAdvancedSsh(tester);
    expect(find.text('Use jump host'), findsOneWidget);
    await tester.ensureVisible(find.text('Use jump host'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use jump host'));
    await tester.pumpAndSettle();
    for (final entry in {
      'Jump host name or IP': 'edge.example',
      'Jump user': 'gateway',
      'Jump port': '2222',
      'Jump password': 'jump-secret'
    }.entries) {
      await _scrollTo(tester, entry.key);
      await tester.enterText(_fieldFinder(entry.key), entry.value);
    }
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result()!.profile.proxyJump?.hostName, 'edge.example');
    expect(result()!.profile.proxyJump?.user, 'gateway');
    expect(result()!.profile.proxyJump?.port, 2222);
    expect(result()!.secret.jumpPassword, 'jump-secret');
    expect(
        result()!.profile.toJson().toString(), isNot(contains('jump-secret')));
  });

  testWidgets('advanced SSH saves timeout and keepalive settings',
      (tester) async {
    final result = await _openEditor(tester, profile: _profile());
    await _openAdvancedSsh(tester);
    for (final entry in {
      'Connect timeout (seconds)': '25',
      'Authentication timeout (seconds)': '35',
      'Keepalive interval (seconds)': '30'
    }.entries) {
      await _scrollTo(tester, entry.key);
      await tester.enterText(_fieldFinder(entry.key), entry.value);
    }
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result()!.profile.toJson()['sshOptions'], {
      'connectTimeoutSeconds': 25,
      'authTimeoutSeconds': 35,
      'keepAliveIntervalSeconds': 30
    });
  });

  testWidgets('removing a jump host clears its saved credentials',
      (tester) async {
    final profile = _profile().copyWith(
        proxyJump:
            const JumpHostProfile(hostName: 'edge.example', user: 'gateway'));
    final result = await _openEditor(tester, profile: profile);
    await _openAdvancedSsh(tester);
    expect(find.text('Use jump host'), findsOneWidget);
    await _scrollTo(tester, 'Jump password');
    await tester.enterText(_fieldFinder('Jump password'), 'jump-secret');
    await tester.ensureVisible(find.text('Use jump host'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use jump host'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result()!.profile.proxyJump, isNull);
    expect(result()!.secret.jumpPassword, anyOf(isNull, isEmpty));
  });

  testWidgets('host editor exposes all app-server modes', (tester) async {
    await _openEditor(tester, profile: _profile());
    await _scrollTo(tester, 'Shared');

    expect(find.text('Shared'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);
    expect(find.text('Isolated'), findsOneWidget);
  });

  testWidgets('custom mode requires an absolute Unix socket', (tester) async {
    final result = await _openEditor(tester, profile: _profile());
    await _scrollTo(tester, 'Custom');
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();

    await tester.enterText(
      _fieldFinder('App-server Unix socket'),
      'relative.sock',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Enter an absolute Unix socket path.'), findsOneWidget);
    expect(result(), isNull);

    await tester.enterText(
      _fieldFinder('App-server Unix socket'),
      '/run/user/1000/codex.sock',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result(), isNotNull);
    expect(result()!.profile.appServerMode, AppServerMode.custom);
    expect(
      result()!.profile.customAppServerSocket,
      '/run/user/1000/codex.sock',
    );
  });

  testWidgets('SSH import preserves the selected app-server mode',
      (tester) async {
    final profile = _profile(
      appServerMode: AppServerMode.custom,
      customAppServerSocket: '/tmp/custom.sock',
    );
    await _openEditor(tester, profile: profile);
    await tester.tap(find.text('Import SSH config'));
    await tester.pumpAndSettle();
    await tester.enterText(
      _fieldFinder('~/.ssh/config contents'),
      'Host pi\n  HostName 192.0.2.20\n  User codex\n',
    );
    await tester.enterText(_fieldFinder('Host alias'), 'pi');
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, 'App-server Unix socket');

    expect(
      _textField(tester, 'App-server Unix socket').controller!.text,
      '/tmp/custom.sock',
    );
  });

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

    await _openAdvancedSsh(tester);

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
    await tester.tap(find.text('Import'));
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
    await tester.tap(find.text('Save'));
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
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      find.text('Duplicate environment variable TOKEN on line 2.'),
      findsOneWidget,
    );
    expect(result(), isNull);
  });

  testWidgets('invalid collapsed environment expands to reveal its error', (
    tester,
  ) async {
    final result = await _openEditor(tester, profile: _profile());
    await _openAdvancedSsh(tester);
    await tester.enterText(
      _fieldFinder('Environment variables'),
      'VALID=ok\nmissing-equals',
    );
    await tester.tap(find.text('Advanced SSH'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(result(), isNull);
    expect(
      find.text(
        'Invalid environment assignment on line 2: '
        'Environment assignment must contain an equals sign.',
      ),
      findsOneWidget,
    );
    expect(
      _textField(tester, 'Environment variables').controller!.text,
      'VALID=ok\nmissing-equals',
    );
  });

  testWidgets('valid Save returns the parsed environment map', (tester) async {
    final result = await _openEditor(tester, profile: _profile());
    await _openAdvancedSsh(tester);
    await tester.enterText(
      _fieldFinder('Environment variables'),
      'LC_CODEX_BACKEND=sub2api\nTOKEN=a=b',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result(), isNotNull);
    expect(result()!.profile.environment, {
      'LC_CODEX_BACKEND': 'sub2api',
      'TOKEN': 'a=b',
    });
  });
}

HostProfile _profile({
  Map<String, String> environment = const {},
  AppServerMode appServerMode = AppServerMode.shared,
  String? customAppServerSocket,
}) =>
    HostProfile(
      id: 'pi',
      label: 'Raspberry Pi',
      hostName: '192.0.2.10',
      user: 'codex',
      port: 22,
      environment: environment,
      appServerMode: appServerMode,
      customAppServerSocket: customAppServerSocket,
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

Future<void> _scrollTo(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(
    find.text(text),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

Finder _fieldFinder(String label) => find.widgetWithText(TextFormField, label);

TextFormField _textField(WidgetTester tester, String label) =>
    tester.widget<TextFormField>(_fieldFinder(label));
