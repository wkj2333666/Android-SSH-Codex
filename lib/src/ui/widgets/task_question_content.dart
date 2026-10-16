import '../../tasks/task_reducer.dart';

/// Some servers send both structured questions and their Markdown fallback.
/// Remove only complete matching blocks from presentation, never from history
/// or clipboard text. Partial matches and fenced code remain untouched.
String questionMessageBody(String text, List<TaskQuestion> questions) {
  if (questions.isEmpty) return text;
  final lines = text.split('\n');
  final body = <String>[];
  var removed = false;
  String? fence;
  var index = 0;
  while (index < lines.length) {
    final line = lines[index];
    final marker = RegExp(r'^\s*(`{3,}|~{3,})').firstMatch(line)?.group(1);
    if (marker != null) {
      if (fence == null) {
        fence = marker;
      } else if (marker[0] == fence[0] && marker.length >= fence.length) {
        fence = null;
      }
      body.add(line);
      index++;
      continue;
    }
    int? end;
    if (fence == null && !line.startsWith('    ') && !line.startsWith('\t')) {
      for (final question in questions) {
        var cursor = _matchText(lines, index, question.title, option: false);
        if (cursor == null) continue;
        for (final option in question.options) {
          if (cursor == null) break;
          while (cursor < lines.length && lines[cursor].trim().isEmpty) {
            cursor++;
          }
          cursor = _matchText(lines, cursor, option, option: true);
          if (cursor == null) break;
        }
        if (cursor != null) {
          end = cursor;
          break;
        }
      }
    }
    if (end == null) {
      body.add(line);
      index++;
    } else {
      removed = true;
      index = end;
    }
  }
  if (!removed) return text;
  return body.join('\n').replaceAll(RegExp(r'^\n+|\n+$'), '');
}

int? _matchText(List<String> lines, int start, String text,
    {required bool option}) {
  if (start >= lines.length) return null;
  final listPrefix = RegExp(r'^\s*(?:[-+*]|\d+[.)])\s+');
  if (option && !listPrefix.hasMatch(lines[start])) return null;
  final expected = _normalize(text);
  if (expected.isEmpty) return null;
  var actual = '';
  for (var index = start; index < lines.length; index++) {
    if (lines[index].trim().isEmpty) return null;
    if (index != start && listPrefix.hasMatch(lines[index])) return null;
    final line = index == start
        ? lines[index]
            .replaceFirst(listPrefix, '')
            .replaceFirst(RegExp(r'^\s*#{1,6}\s+'), '')
        : lines[index];
    actual += _normalize(line);
    if (actual == expected) return index + 1;
    if (!expected.startsWith(actual)) return null;
  }
  return null;
}

String _normalize(String value) => value.replaceAll(RegExp(r'[\s*_`]+'), '');
