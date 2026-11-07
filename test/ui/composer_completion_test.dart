import 'package:android_ssh_codex/src/protocol/codex_remote_api.dart';
import 'package:android_ssh_codex/src/ui/composer_completion.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const skills = [
    RemoteSkill(
      name: 'openai-docs',
      description: 'Read official docs',
      path: '/skills/openai-docs/SKILL.md',
    ),
    RemoteSkill(
      name: 'systematic-debugging',
      description: 'Debug methodically',
      path: '/skills/systematic-debugging/SKILL.md',
    ),
  ];

  test('slash completion exposes only stable task commands', () {
    final results = composerCompletions('/g', 2, skills);

    expect(results.map((item) => item.value), ['/goal']);
    expect(
      composerCompletions('/', 1, skills).map((item) => item.value),
      ['/goal', '/compact', '/skills', '/mcp', '/permissions', '/interrupt'],
    );
  });

  test('MCP and permission commands are recognized before sending', () {
    expect(composerCompletions('/mc', 3, skills).single.value, '/mcp');
    expect(composerCompletions('/perm', 5, skills).single.value, '/permissions');
  });

  test('dollar completion filters enabled remote skills', () {
    final results = composerCompletions(r'Use $sys', 8, skills);

    expect(results.single.value, r'$systematic-debugging');
    expect(results.single.kind, ComposerCompletionKind.skill);
  });

  test('selection removes only the active completion token', () {
    final edit = removeActiveCompletionToken(r'Please use $open', 16);

    expect(edit.text, 'Please use ');
    expect(edit.cursor, 11);
  });
}
