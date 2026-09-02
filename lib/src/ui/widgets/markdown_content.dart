import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import 'formula_markdown.dart';

typedef ExternalLinkOpener = Future<bool> Function(Uri uri);

Future<bool> launchExternalLink(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

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
    super.key,
  });

  final String text;
  final ExternalLinkOpener openExternalLink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
      },
      onTapLink: (_, href, __) {
        unawaited(openWebLink(context, href, openExternalLink));
      },
      imageBuilder: (uri, title, alt) => _BlockedImage(alt: alt),
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        code: theme.textTheme.bodyMedium?.copyWith(
          fontFamily: 'monospace',
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
