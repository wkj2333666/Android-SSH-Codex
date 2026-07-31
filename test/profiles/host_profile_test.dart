import 'package:android_ssh_codex/src/profiles/host_profile.dart';
import 'package:android_ssh_codex/src/ssh_config/ssh_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('creates a profile from an SSH config alias', () {
    final config = SshConfig.parse('''
Host pi
  HostName 192.0.2.10
  User codex
  Port 2222
  IdentityFile ~/.ssh/pi
  SetEnv LC_CODEX_BACKEND=sub2api CODEX_LABEL="mobile client"
''');

    final profile = HostProfile.fromResolved(config.resolve('pi'));

    expect(profile.label, 'pi');
    expect(profile.hostName, '192.0.2.10');
    expect(profile.user, 'codex');
    expect(profile.port, 2222);
    expect(profile.identityFileHint, '~/.ssh/pi');
    expect(profile.environment, {
      'LC_CODEX_BACKEND': 'sub2api',
      'CODEX_LABEL': 'mobile client',
    });
  });

  test('explicit app values override imported config defaults', () {
    final imported = HostProfile.fromResolved(
      SshConfig.parse('''
Host work
  HostName old.example
  User imported
''').resolve('work'),
    );

    final overridden = imported.copyWith(
      hostName: 'new.example',
      user: 'mobile',
      port: 2200,
    );

    expect(overridden.hostName, 'new.example');
    expect(overridden.user, 'mobile');
    expect(overridden.port, 2200);
  });

  test('round-trips non-secret profile metadata as JSON', () {
    final profile = HostProfile(
      id: 'host-1',
      label: 'Workstation',
      hostName: 'dev.example',
      user: 'coder',
      port: 22,
      authMethod: HostAuthMethod.privateKey,
      identityFileHint: '~/.ssh/id_ed25519',
      environment: const {
        'LC_CODEX_BACKEND': 'sub2api',
        'CODEX_LABEL': 'mobile client',
      },
    );

    expect(HostProfile.fromJson(profile.toJson()), profile);
    expect(profile.toJson()['environment'], {
      'LC_CODEX_BACKEND': 'sub2api',
      'CODEX_LABEL': 'mobile client',
    });
    expect(profile.toJson().keys, isNot(contains('password')));
    expect(profile.toJson().keys, isNot(contains('privateKey')));
  });

  test('loads old profile JSON without an environment', () {
    final profile = HostProfile.fromJson({
      'id': 'legacy',
      'label': 'Legacy host',
      'hostName': 'legacy.example',
      'user': 'coder',
      'port': 22,
      'authMethod': 'password',
    });

    expect(profile.environment, isEmpty);
    expect(profile.toJson(), isNot(contains('environment')));
  });

  test('copyWith can replace and clear an environment', () {
    final profile = HostProfile(
      id: 'host-1',
      label: 'Workstation',
      hostName: 'dev.example',
      user: 'coder',
      port: 22,
      environment: const {'LC_CODEX_BACKEND': 'sub2api'},
    );

    final replaced = profile.copyWith(environment: const {'MODE': 'review'});
    final cleared = replaced.copyWith(environment: const {});

    expect(replaced.environment, {'MODE': 'review'});
    expect(cleared.environment, isEmpty);
    expect(cleared.toJson(), isNot(contains('environment')));
  });

  test('uses environment map contents for equality and hashCode', () {
    HostProfile profileWith(Map<String, String> environment) => HostProfile(
          id: 'host-1',
          label: 'Workstation',
          hostName: 'dev.example',
          user: 'coder',
          port: 22,
          environment: environment,
        );

    final first = profileWith({
      'LC_CODEX_BACKEND': 'sub2api',
      'CODEX_LABEL': 'mobile client',
    });
    final sameContentsDifferentOrder = profileWith({
      'CODEX_LABEL': 'mobile client',
      'LC_CODEX_BACKEND': 'sub2api',
    });
    final differentValue = profileWith({
      'LC_CODEX_BACKEND': 'official',
      'CODEX_LABEL': 'mobile client',
    });

    expect(first, sameContentsDifferentOrder);
    expect(first.hashCode, sameContentsDifferentOrder.hashCode);
    expect(first, isNot(differentValue));
  });

  test('defensively copies and exposes an immutable environment', () {
    final source = <String, String>{'LC_CODEX_BACKEND': 'sub2api'};
    final profile = HostProfile(
      id: 'host-1',
      label: 'Workstation',
      hostName: 'dev.example',
      user: 'coder',
      port: 22,
      environment: source,
    );

    source['LC_CODEX_BACKEND'] = 'changed';

    expect(profile.environment, {'LC_CODEX_BACKEND': 'sub2api'});
    expect(
      () => profile.environment['ADDED'] = 'value',
      throwsUnsupportedError,
    );
  });
}
