import 'package:android_ssh_codex/src/ssh_config/ssh_environment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseSshEnvironmentAssignment', () {
    test('parses a name and value', () {
      final assignment =
          parseSshEnvironmentAssignment('LC_CODEX_BACKEND=sub2api');

      expect(assignment.key, 'LC_CODEX_BACKEND');
      expect(assignment.value, 'sub2api');
    });

    test('splits only on the first equals sign', () {
      final assignment = parseSshEnvironmentAssignment('TOKEN=a=b');

      expect(assignment.key, 'TOKEN');
      expect(assignment.value, 'a=b');
    });

    test('permits an empty value', () {
      final assignment = parseSshEnvironmentAssignment('EMPTY=');

      expect(assignment.key, 'EMPTY');
      expect(assignment.value, isEmpty);
    });

    test('rejects a missing equals sign', () {
      expect(
        () => parseSshEnvironmentAssignment('MISSING_VALUE'),
        throwsFormatException,
      );
    });

    test('rejects an invalid environment name', () {
      expect(
        () => parseSshEnvironmentAssignment('INVALID-NAME=value'),
        throwsFormatException,
      );
    });

    test('rejects forbidden controls without leaking values', () {
      const invalidValues = {
        'NUL': 'nul-secret\u0000tail',
        'carriage return': 'cr-secret\rtail',
        'newline': 'lf-secret\ntail',
      };

      for (final invalidValue in invalidValues.entries) {
        expect(
          () => parseSshEnvironmentAssignment('TOKEN=${invalidValue.value}'),
          throwsA(
            isA<FormatException>().having(
              (error) => error.toString(),
              'safe error',
              isNot(contains('secret')),
            ),
          ),
          reason: invalidValue.key,
        );
      }
    });
  });

  group('SSH environment lines', () {
    test('ignores blank lines and preserves equals signs in values', () {
      final environment = parseSshEnvironmentLines('''

FIRST=one

TOKEN=a=b
EMPTY=
''');

      expect(environment, {
        'FIRST': 'one',
        'TOKEN': 'a=b',
        'EMPTY': '',
      });
    });

    test('rejects duplicate names with a one-based line number', () {
      expect(
        () => parseSshEnvironmentLines(
          'NAME=first-secret\nOTHER=value\nNAME=second-secret',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.toString(),
            'message',
            allOf(
              contains('line 3'),
              contains('NAME'),
              isNot(contains('first-secret')),
              isNot(contains('second-secret')),
            ),
          ),
        ),
      );
    });

    test('reports an invalid line without exposing its value', () {
      expect(
        () => parseSshEnvironmentLines(
          'GOOD=visible\nINVALID-NAME=line-secret',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.toString(),
            'safe line-specific message',
            allOf(contains('line 2'), isNot(contains('line-secret'))),
          ),
        ),
      );
    });

    test('formats assignments in name order', () {
      expect(
        formatSshEnvironmentLines({
          'Z_LAST': 'three',
          'A_FIRST': 'one',
          'M_MIDDLE': 'two=parts',
        }),
        'A_FIRST=one\nM_MIDDLE=two=parts\nZ_LAST=three',
      );
    });

    test('validates valid input', () {
      expect(
        validateSshEnvironmentLines('A=one\nTOKEN=a=b\n\nEMPTY='),
        isNull,
      );
    });

    test('returns a safe line-specific validation message', () {
      final message = validateSshEnvironmentLines(
        'GOOD=value\nINVALID-NAME=validation-secret',
      );

      expect(message, isNotNull);
      expect(message, contains('line 2'));
      expect(message, isNot(contains('validation-secret')));
    });
  });
}
