import 'package:android_ssh_codex/src/ssh_config/ssh_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SshConfig', () {
    test('resolves an alias and fills defaults from Host star', () {
      final config = SshConfig.parse('''
Host work
  HostName dev.internal
  User coder
  Port 2222

Host *
  User fallback
  IdentityFile "~/.ssh/id ed25519"
''');

      final host = config.resolve('work');

      expect(host.hostName, 'dev.internal');
      expect(host.user, 'coder');
      expect(host.port, 2222);
      expect(host.identityFiles, ['~/.ssh/id ed25519']);
    });

    test('uses OpenSSH first obtained value across matching sections', () {
      final config = SshConfig.parse('''
Host *.prod
  User deploy
  Port 2200
Host api.prod
  User root
  HostName 10.0.0.8
''');

      final host = config.resolve('api.prod');

      expect(host.user, 'deploy');
      expect(host.port, 2200);
      expect(host.hostName, '10.0.0.8');
    });

    test('supports negated wildcard patterns', () {
      final config = SshConfig.parse('''
Host *.example !bastion.example
  User service
Host *
  User human
''');

      expect(config.resolve('api.example').user, 'service');
      expect(config.resolve('bastion.example').user, 'human');
    });

    test('resolves one-hop ProxyJump through the same config', () {
      final config = SshConfig.parse('''
Host edge
  HostName edge.example
  User jump
  Port 2201
Host private
  HostName 10.2.0.9
  User codex
  ProxyJump edge
''');

      final host = config.resolve('private');

      expect(host.proxyJump?.alias, 'edge');
      expect(host.proxyJump?.hostName, 'edge.example');
      expect(host.proxyJump?.user, 'jump');
      expect(host.proxyJump?.port, 2201);
    });

    test('reports unsupported multi-hop ProxyJump without guessing', () {
      final config = SshConfig.parse('''
Host private
  HostName 10.2.0.9
  ProxyJump edge,gate
''');

      final host = config.resolve('private');

      expect(host.proxyJump, isNull);
      expect(host.warnings.single, contains('one ProxyJump'));
    });

    test('strips comments outside quotes and preserves hashes in quotes', () {
      final config = SshConfig.parse('''
Host hash
  HostName "box#1.example" # visible comment
''');

      expect(config.resolve('hash').hostName, 'box#1.example');
    });

    test('does not leak directives from unsupported Match blocks', () {
      final config = SshConfig.parse('''
Host work
  HostName work.example
  User coder
Match host work exec "test -f /tmp/admin"
  User root
  ProxyJump privileged
Host other
  HostName other.example
''');

      final work = config.resolve('work');

      expect(work.user, 'coder');
      expect(work.proxyJump, isNull);
      expect(work.warnings, contains(contains('Match')));
    });

    test('resolves multiple SetEnv directives and assignments', () {
      final config = SshConfig.parse('''
Host single
  SetEnv ONLY=one
Host multiple
  SetEnv FIRST=one SECOND=two
  SetEnv THIRD=three
''');

      expect(config.resolve('single').environment, {'ONLY': 'one'});
      expect(config.resolve('multiple').environment, {
        'FIRST': 'one',
        'SECOND': 'two',
        'THIRD': 'three',
      });
    });

    test('preserves quoted spaces and additional equals signs in values', () {
      final config = SshConfig.parse('''
Host values
  SetEnv GREETING="hello world" TOKEN=a=b
''');

      expect(config.resolve('values').environment, {
        'GREETING': 'hello world',
        'TOKEN': 'a=b',
      });
    });

    test('uses the first value per variable across matching sections', () {
      final config = SshConfig.parse('''
Host *.prod
  SetEnv BACKEND=first SHARED=from-pattern
Host api.prod
  SetEnv BACKEND=later REGION=us-east
''');

      expect(config.resolve('api.prod').environment, {
        'BACKEND': 'first',
        'SHARED': 'from-pattern',
        'REGION': 'us-east',
      });
    });

    test('keeps target values while adding later Host star defaults', () {
      final config = SshConfig.parse('''
Host target
  SetEnv TARGET=target-value
Host *
  SetEnv TARGET=fallback-value GLOBAL=global-value
''');

      final host = config.resolve('target');

      expect(host.environment, {
        'TARGET': 'target-value',
        'GLOBAL': 'global-value',
      });
      expect(host.warnings, hasLength(1));
      expect(host.warnings.single, contains('TARGET'));
      expect(host.warnings.single, isNot(contains('target-value')));
      expect(host.warnings.single, isNot(contains('fallback-value')));
      expect(host.warnings.single, isNot(contains('global-value')));
    });

    test('warns safely about conflicting duplicate values', () {
      final config = SshConfig.parse('''
Host duplicate
  SetEnv TOKEN=first-secret
  SetEnv TOKEN=second-secret
''');

      final host = config.resolve('duplicate');

      expect(host.environment, {'TOKEN': 'first-secret'});
      expect(host.warnings, hasLength(1));
      expect(host.warnings.single, contains('TOKEN'));
      expect(host.warnings.single, isNot(contains('first-secret')));
      expect(host.warnings.single, isNot(contains('second-secret')));
    });

    test('omits invalid assignments while preserving valid assignments', () {
      final config = SshConfig.parse('''
Host partial
  SetEnv GOOD=good-secret INVALID-NAME=invalid-secret ALSO=also-secret
''');

      final host = config.resolve('partial');

      expect(host.environment, {
        'GOOD': 'good-secret',
        'ALSO': 'also-secret',
      });
      expect(host.warnings, hasLength(1));
      expect(host.warnings.single, contains('SetEnv'));
      expect(host.warnings.single, isNot(contains('good-secret')));
      expect(host.warnings.single, isNot(contains('invalid-secret')));
      expect(host.warnings.single, isNot(contains('also-secret')));
    });

    test('keeps IPQoS unsupported', () {
      final config = SshConfig.parse('''
Host qos
  IPQoS none
''');

      expect(
        config.resolve('qos').warnings,
        contains('Unsupported SSH directive: IPQoS'),
      );
    });

    test('continues to parse equals syntax for existing directives', () {
      final config = SshConfig.parse('''
Host=alias
  HostName=value.example
  Port=2222
''');

      final host = config.resolve('alias');

      expect(host.hostName, 'value.example');
      expect(host.port, 2222);
    });

    test('exposes an immutable resolved environment', () {
      final config = SshConfig.parse('''
Host immutable
  SetEnv ORIGINAL=value
''');
      final environment = config.resolve('immutable').environment;

      expect(
        () => environment['ADDED'] = 'value',
        throwsUnsupportedError,
      );
    });
  });
}
