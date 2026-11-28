import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

class FormulaInlineSyntax extends md.InlineSyntax {
  FormulaInlineSyntax()
      : super(
          r'(?<!\$)\$(?![\s$])((?:\\[^\n]|[^\\$\n\x60])+?)(?<!\s)\$(?![$0-9])'
          r'|\\\(([^\n]+?)\\\)',
        );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(_formula(match.group(1) ?? match.group(2)!, display: false));
    return true;
  }
}

md.Element _formula(String source, {required bool display}) =>
    md.Element.empty('latex')
      ..attributes['source'] = source.trim()
      ..attributes['display'] = display.toString();

class FormulaBlockSyntax extends md.BlockSyntax {
  static final _start = RegExp(r'^ {0,3}(\$\$|\\\[)(.*)$');
  static final _fencedCode = RegExp(r'^ {0,3}(?:\x60{3,}|~{3,})');

  @override
  RegExp get pattern => _start;

  String _closingDelimiter(String opener) => opener == r'$$' ? r'$$' : r'\]';

  // Only claim completed blocks. During streaming an unclosed delimiter
  // must not turn the rest of the reply into TeX.
  @override
  bool canParse(md.BlockParser parser) {
    final opening = _start.firstMatch(parser.current.content);
    if (opening == null) return false;
    return _closingLine(parser, opening) != null;
  }

  int? _closingLine(md.BlockParser parser, Match opening) {
    final end = _closingDelimiter(opening.group(1)!);
    final rest = opening.group(2)!.trim();
    if (rest.endsWith(end) && rest.length > end.length) return 0;
    for (var offset = 1;; offset++) {
      final line = parser.peek(offset);
      if (line == null || _fencedCode.hasMatch(line.content)) return null;
      if (line.content.trimRight().endsWith(end)) return offset;
      if (_start.hasMatch(line.content)) return null;
    }
  }

  @override
  md.Node parse(md.BlockParser parser) {
    final opening = _start.firstMatch(parser.current.content)!;
    final offset = _closingLine(parser, opening)!;
    final end = _closingDelimiter(opening.group(1)!);
    final first = opening.group(2)!;
    parser.advance();
    if (offset == 0) return _paragraph(_stripClosingDelimiter(first, end));

    final lines = <String>[first];
    for (var i = 1; i < offset; i++) {
      lines.add(parser.current.content);
      parser.advance();
    }
    lines.add(_stripClosingDelimiter(parser.current.content, end));
    parser.advance();
    return _paragraph(lines.join('\n'));
  }

  String _stripClosingDelimiter(String line, String delimiter) {
    final trimmed = line.trimRight();
    return trimmed.substring(0, trimmed.length - delimiter.length);
  }

  md.Element _paragraph(String source) =>
      md.Element('p', [_formula(source, display: true)]);
}

class FormulaElementBuilder extends MarkdownElementBuilder {
  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final display = element.attributes['display'] == 'true';
    final source = element.attributes['source']!;
    final theme = Theme.of(context);
    final style =
        (preferredStyle ?? parentStyle ?? theme.textTheme.bodyMedium)?.copyWith(
      color:
          (preferredStyle ?? parentStyle)?.color ?? theme.colorScheme.onSurface,
    );
    return SingleChildScrollView(
      primary: false,
      scrollDirection: Axis.horizontal,
      padding: display ? const EdgeInsets.symmetric(vertical: 6) : null,
      child: Math.tex(
        source,
        mathStyle: display ? MathStyle.display : MathStyle.text,
        textStyle: style,
        onErrorFallback: (_) =>
            Text(source, style: style?.copyWith(fontFamily: 'monospace')),
      ),
    );
  }
}
