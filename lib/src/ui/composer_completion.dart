import '../protocol/codex_remote_api.dart';

enum ComposerCompletionKind { command, skill }

final class ComposerCompletion {
  const ComposerCompletion({
    required this.kind,
    required this.value,
    required this.description,
  });

  final ComposerCompletionKind kind;
  final String value;
  final String description;
}

final class ComposerEdit {
  const ComposerEdit({required this.text, required this.cursor});

  final String text;
  final int cursor;
}

const _commands = [
  ComposerCompletion(
    kind: ComposerCompletionKind.command,
    value: '/goal',
    description: 'View or edit the task goal',
  ),
  ComposerCompletion(
    kind: ComposerCompletionKind.command,
    value: '/compact',
    description: 'Compact older task context',
  ),
  ComposerCompletion(
    kind: ComposerCompletionKind.command,
    value: '/skills',
    description: 'Choose an enabled project skill',
  ),
  ComposerCompletion(
    kind: ComposerCompletionKind.command,
    value: '/mcp',
    description: 'View configured MCP servers and tools',
  ),
  ComposerCompletion(
    kind: ComposerCompletionKind.command,
    value: '/permissions',
    description: 'Choose permissions for the next new turn',
  ),
  ComposerCompletion(
    kind: ComposerCompletionKind.command,
    value: '/interrupt',
    description: 'Stop the active turn',
  ),
];

List<ComposerCompletion> composerCompletions(
  String text,
  int cursor,
  List<RemoteSkill> skills,
) {
  final token = _activeToken(text, cursor);
  if (token == null) return const [];
  final normalized = token.value.toLowerCase();
  if (normalized.startsWith('/')) {
    return _commands
        .where((command) => command.value.startsWith(normalized))
        .toList(growable: false);
  }
  if (normalized.startsWith(r'$')) {
    return skills
        .where((skill) =>
            skill.name.toLowerCase().startsWith(normalized.substring(1)))
        .map(
          (skill) => ComposerCompletion(
            kind: ComposerCompletionKind.skill,
            value: r'$' + skill.name,
            description: skill.description,
          ),
        )
        .toList(growable: false);
  }
  return const [];
}

bool hasActiveSkillCompletion(String text, int cursor) =>
    _activeToken(text, cursor)?.value.startsWith(r'$') ?? false;

ComposerEdit removeActiveCompletionToken(String text, int cursor) {
  final token = _activeToken(text, cursor);
  if (token == null) return ComposerEdit(text: text, cursor: cursor);
  var end = cursor.clamp(0, text.length).toInt();
  while (end < text.length && !_isWhitespace(text.codeUnitAt(end))) {
    end++;
  }
  return ComposerEdit(
    text: text.replaceRange(token.start, end, ''),
    cursor: token.start,
  );
}

_CompletionToken? _activeToken(String text, int cursor) {
  if (cursor < 0 || cursor > text.length) return null;
  var start = cursor;
  while (start > 0 && !_isWhitespace(text.codeUnitAt(start - 1))) {
    start--;
  }
  final value = text.substring(start, cursor);
  if (value.isEmpty || (!value.startsWith('/') && !value.startsWith(r'$'))) {
    return null;
  }
  return _CompletionToken(start: start, value: value);
}

bool _isWhitespace(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D;

final class _CompletionToken {
  const _CompletionToken({required this.start, required this.value});

  final int start;
  final String value;
}
