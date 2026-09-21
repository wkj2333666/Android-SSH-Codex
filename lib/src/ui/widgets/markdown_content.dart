import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import 'formula_markdown.dart';

typedef ExternalLinkOpener = Future<bool> Function(Uri uri);
typedef MarkdownTextCopier = Future<void> Function(String text);

Future<bool> launchExternalLink(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

Future<void> copyMarkdownText(String text) =>
    Clipboard.setData(ClipboardData(text: text));

Uri? safeWebUri(String? value) {
  if (value == null) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty) return null;
  final scheme = uri.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https' ? uri : null;
}

Future<void> openWebLink(
  BuildContext context,
  String? value,
  ExternalLinkOpener opener,
) async {
  final uri = safeWebUri(value);
  if (uri == null) {
    _showLinkError(context, 'Only HTTP and HTTPS links can be opened.');
    return;
  }
  try {
    if (!await opener(uri) && context.mounted) {
      _showLinkError(context, 'Could not open link.');
    }
  } catch (_) {
    if (context.mounted) _showLinkError(context, 'Could not open link.');
  }
}

void _showLinkError(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(message)),
  );
}

class MarkdownContent extends StatelessWidget {
  const MarkdownContent({
    required this.text,
    this.openExternalLink = launchExternalLink,
    this.copyText = copyMarkdownText,
    super.key,
  });

  final String text;
  final ExternalLinkOpener openExternalLink;
  final MarkdownTextCopier copyText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codeTextStyle = theme.textTheme.bodyMedium?.copyWith(
      fontFamily: 'monospace',
    );
    return MarkdownBody(
      data: text,
      selectable: true,
      extensionSet: md.ExtensionSet(
        [
          FormulaBlockSyntax(),
          ...md.ExtensionSet.gitHubFlavored.blockSyntaxes,
        ],
        [
          FormulaInlineSyntax(),
          ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
        ],
      ),
      builders: {
        'latex': FormulaElementBuilder(textStyle: theme.textTheme.bodyMedium),
        'pre': CodeBlockElementBuilder(
          copyText: copyText,
          textStyle: codeTextStyle,
        ),
      },
      onTapLink: (_, href, __) {
        unawaited(openWebLink(context, href, openExternalLink));
      },
      imageBuilder: (uri, title, alt) => _BlockedImage(alt: alt),
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        code: codeTextStyle?.copyWith(
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
        codeblockDecoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}

class CodeBlockElementBuilder extends MarkdownElementBuilder {
  CodeBlockElementBuilder({required this.copyText, required this.textStyle});

  final MarkdownTextCopier copyText;
  final TextStyle? textStyle;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitText(md.Text text, TextStyle? _) {
    return _CopyableCodeBlock(
      text: text.text,
      style: textStyle,
      copyText: copyText,
    );
  }
}

class _CopyableCodeBlock extends StatelessWidget {
  const _CopyableCodeBlock({
    required this.text,
    required this.style,
    required this.copyText,
  });

  final String text;
  final TextStyle? style;
  final MarkdownTextCopier copyText;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const Key('markdown-code-block'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                tooltip: 'Copy code',
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                onPressed: () => unawaited(
                  _copyCode(context, text, copyText),
                ),
                icon: const Icon(Icons.copy_all_outlined),
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(text, style: style),
          ),
        ],
      ),
    );
  }
}

Future<void> _copyCode(
  BuildContext context,
  String text,
  MarkdownTextCopier copyText,
) async {
  try {
    await copyText(text);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Code copied')),
    );
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not copy code.')),
    );
  }
}

class _BlockedImage extends StatelessWidget {
  const _BlockedImage({this.alt});

  final String? alt;

  @override
  Widget build(BuildContext context) => Semantics(
        label: alt,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.image_not_supported_outlined, size: 16),
                SizedBox(width: 6),
                Text('External image blocked'),
              ],
            ),
          ),
        ),
      );
}
