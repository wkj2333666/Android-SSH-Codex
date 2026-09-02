import 'dart:async';

import 'package:flutter/material.dart';

import 'markdown_content.dart';

const _gitDirectiveNames = {
  'git-stage',
  'git-commit',
  'git-create-branch',
  'git-push',
  'git-create-pr',
};

final _directivePattern = RegExp(
  r'::([a-z][a-z0-9-]*)\{((?:[^"{}]|"(?:\\.|[^"\\])*")*)\}',
);
final _attributePattern = RegExp(
  r'([A-Za-z][A-Za-z0-9]*)=(?:"((?:\\.|[^"\\])*)"|([^\s]+))',
);

final class CodexGitDirective {
  const CodexGitDirective(this.name, this.attributes);

  final String name;
  final Map<String, String> attributes;

  String? get branch => attributes['branch'];
  Uri? get webUri => safeWebUri(attributes['url']);
  bool get isDraft => attributes['isDraft'] == 'true';
}

final class ParsedCodexDirectiveContent {
  const ParsedCodexDirectiveContent({
    required this.markdown,
    required this.directives,
  });

  final String markdown;
  final List<CodexGitDirective> directives;
}

ParsedCodexDirectiveContent parseCodexDirectiveContent(String input) {
  final directives = <CodexGitDirective>[];
  final remaining = StringBuffer();
  String? fenceMarker;
  var fenceLength = 0;
  for (final match in _linePattern.allMatches(input)) {
    final rawLine = match.group(0)!;
    if (rawLine.isEmpty) continue;
    final line = _withoutLineEnding(rawLine);
    if (fenceMarker == null) {
      final fence = _openingFencePattern.firstMatch(line);
      if (fence != null) {
        final marker = fence.group(1)!;
        fenceMarker = marker[0];
        fenceLength = marker.length;
        remaining.write(rawLine);
        continue;
      }
    } else {
      if (_isClosingFence(line, fenceMarker, fenceLength)) {
        fenceMarker = null;
        fenceLength = 0;
      }
      remaining.write(rawLine);
      continue;
    }
    final lineDirectives = _parseDirectiveLine(line);
    if (lineDirectives == null) {
      remaining.write(rawLine);
    } else {
      directives.addAll(lineDirectives);
    }
  }
  return ParsedCodexDirectiveContent(
    markdown: remaining.toString(),
    directives: List.unmodifiable(directives),
  );
}

final _linePattern = RegExp(r'[^\r\n]*(?:\r\n|\r|\n|$)');
final _openingFencePattern = RegExp(r'^[ ]{0,3}(`{3,}|~{3,})');

bool _isClosingFence(String line, String marker, int minimumLength) => RegExp(
      '^[ ]{0,3}${RegExp.escape(marker)}{$minimumLength,}[ \\t]*\$',
    ).hasMatch(line);

String _withoutLineEnding(String line) {
  if (line.endsWith('\r\n')) return line.substring(0, line.length - 2);
  if (line.endsWith('\r') || line.endsWith('\n')) {
    return line.substring(0, line.length - 1);
  }
  return line;
}

List<CodexGitDirective>? _parseDirectiveLine(String line) {
  if (line.startsWith('    ') || line.startsWith('\t')) return null;
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;
  final directives = <CodexGitDirective>[];
  var cursor = 0;
  while (cursor < trimmed.length) {
    final match = _directivePattern.matchAsPrefix(trimmed, cursor);
    if (match == null || !_gitDirectiveNames.contains(match.group(1))) {
      return null;
    }
    directives.add(
      CodexGitDirective(
        match.group(1)!,
        _parseAttributes(match.group(2)!),
      ),
    );
    cursor = match.end;
    if (cursor == trimmed.length) break;
    if (!RegExp(r'\s').hasMatch(trimmed[cursor])) return null;
    while (cursor < trimmed.length && RegExp(r'\s').hasMatch(trimmed[cursor])) {
      cursor++;
    }
  }
  return directives;
}

Map<String, String> _parseAttributes(String source) => Map.unmodifiable({
      for (final match in _attributePattern.allMatches(source))
        match.group(1)!: _unescapeAttribute(match.group(2) ?? match.group(3)!),
    });

String _unescapeAttribute(String value) =>
    value.replaceAllMapped(RegExp(r'\\(.)'), (match) => match.group(1)!);

class CodexDirectiveContent extends StatelessWidget {
  const CodexDirectiveContent({
    required this.text,
    this.openExternalLink = launchExternalLink,
    super.key,
  });

  final String text;
  final ExternalLinkOpener openExternalLink;

  @override
  Widget build(BuildContext context) {
    final parsed = parseCodexDirectiveContent(text);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (parsed.markdown.isNotEmpty)
          MarkdownContent(
            text: parsed.markdown,
            openExternalLink: openExternalLink,
          ),
        if (parsed.markdown.isNotEmpty && parsed.directives.isNotEmpty)
          const SizedBox(height: 8),
        if (parsed.directives.isNotEmpty)
          _GitActivityCard(
            directives: parsed.directives,
            openExternalLink: openExternalLink,
          ),
      ],
    );
  }
}

class _GitActivityCard extends StatelessWidget {
  const _GitActivityCard({
    required this.directives,
    required this.openExternalLink,
  });

  final List<CodexGitDirective> directives;
  final ExternalLinkOpener openExternalLink;

  @override
  Widget build(BuildContext context) => Card(
        key: const Key('git-activity-card'),
        margin: EdgeInsets.zero,
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final directive in directives)
                _GitDirectiveRow(
                  directive: directive,
                  openExternalLink: openExternalLink,
                ),
            ],
          ),
        ),
      );
}

class _GitDirectiveRow extends StatelessWidget {
  const _GitDirectiveRow({
    required this.directive,
    required this.openExternalLink,
  });

  final CodexGitDirective directive;
  final ExternalLinkOpener openExternalLink;

  @override
  Widget build(BuildContext context) {
    final uri = directive.webUri;
    final detail = switch (directive.name) {
      'git-create-branch' || 'git-push' => directive.branch,
      'git-create-pr' when directive.isDraft => 'Draft',
      _ => null,
    };
    return InkWell(
      onTap: uri == null
          ? null
          : () => unawaited(
                openWebLink(context, uri.toString(), openExternalLink),
              ),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: 16),
            const SizedBox(width: 7),
            Text(_label, style: Theme.of(context).textTheme.labelMedium),
            if (detail?.isNotEmpty == true) ...[
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  detail!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
            if (uri != null) ...[
              const SizedBox(width: 4),
              const Icon(Icons.open_in_new, size: 14),
            ],
          ],
        ),
      ),
    );
  }

  String get _label => switch (directive.name) {
        'git-stage' => 'Changes staged',
        'git-commit' => 'Commit created',
        'git-create-branch' => 'Branch created',
        'git-push' => 'Pushed',
        'git-create-pr' => 'Pull request',
        _ => 'Git activity',
      };

  IconData get _icon => switch (directive.name) {
        'git-create-branch' => Icons.account_tree_outlined,
        'git-push' => Icons.upload_outlined,
        'git-create-pr' => Icons.call_merge_outlined,
        _ => Icons.check_circle_outline,
      };
}
