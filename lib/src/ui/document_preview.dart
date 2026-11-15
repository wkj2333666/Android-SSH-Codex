import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../attachment_media.dart';
import '../attachments.dart';
import 'preview_browser.dart';
import 'widgets/remote_file_actions.dart';

RemoteFilePreview documentPreviewFor(
        BuildContext context, AppController controller,
        {String? cwd}) =>
    (link, {onProgress, onReady}) => controller.previewDocument(
          link,
          cwd: cwd,
          onProgress: onProgress,
          open: (file, name, kind) async {
            if (!context.mounted) return false;
            onReady?.call();
            await Navigator.of(context, rootNavigator: true).push<void>(
              MaterialPageRoute(
                builder: (_) =>
                    DocumentPreview(file: file, name: name, kind: kind),
              ),
            );
            return true;
          },
        );

class DocumentPreview extends StatefulWidget {
  const DocumentPreview(
      {required this.file, required this.name, required this.kind, super.key});

  final File file;
  final String name;
  final DocumentPreviewKind kind;

  @override
  State<DocumentPreview> createState() => _DocumentPreviewState();
}

class _DocumentPreviewState extends State<DocumentPreview> {
  String? _text;
  MemoryImage? _image;
  int _page = 0;
  int _count = 0;
  bool _loading = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(0);
  }

  Future<void> _load(int page) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (widget.kind == DocumentPreviewKind.text) {
        final text = await widget.file.readAsString();
        if (!mounted) return;
        if (text.contains('\u0000')) throw const FormatException('Not text');
        setState(() => _text = text);
      } else {
        final count = await PreviewBrowser.channel.invokeMethod<int>(
            'renderPdfPage', {'path': widget.file.path, 'page': page});
        if (!mounted) return;
        if (count == null || page >= count) {
          throw const FormatException('Invalid PDF page');
        }
        final png = File('${widget.file.parent.path}/pdf-page.png');
        if (await png.length() > 16 * 1024 * 1024) {
          throw const FormatException('Rendered PDF page too large');
        }
        final image = await png.readAsBytes();
        if (!mounted) return;
        _evictPage();
        setState(() {
          _page = page;
          _count = count;
          _image = MemoryImage(image);
        });
      }
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is PlatformException
            ? error.message ?? 'Could not render the PDF.'
            : widget.kind == DocumentPreviewKind.text
                ? 'Cannot read this file as UTF-8 text.'
                : 'Could not render the PDF.';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _evictPage() {
    final image = _image;
    if (image != null) unawaited(image.evict());
  }

  @override
  void dispose() {
    _evictPage();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final saved = await Attachments.channel.invokeMethod<bool>(
          'saveDownload', {'path': widget.file.path, 'name': widget.name});
      if (saved == true && mounted) _message('File saved');
    } on Exception {
      if (mounted) _message('Could not save the document.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.name, overflow: TextOverflow.ellipsis),
          automaticallyImplyLeading: !_saving,
          actions: [
            IconButton(
              tooltip: 'Download original',
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.download_outlined),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_error!),
                ),
              Expanded(
                child: _text != null
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: SizedBox(
                          width: double.infinity,
                          child: SelectableText(
                            _text!.isEmpty ? 'Empty file' : _text!,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ),
                      )
                    : _image == null
                        ? const SizedBox.shrink()
                        : InteractiveViewer(
                            key: ValueKey(_page),
                            maxScale: 4,
                            child: SizedBox.expand(
                              child: Image(
                                image: _image!,
                                fit: BoxFit.contain,
                                semanticLabel: 'PDF page ${_page + 1}',
                              ),
                            ),
                          ),
              ),
              if (_count > 0)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                        tooltip: 'Previous page',
                        onPressed: _loading || _page == 0
                            ? null
                            : () => _load(_page - 1),
                        icon: const Icon(Icons.chevron_left)),
                    Text('${_page + 1} / $_count'),
                    IconButton(
                        tooltip: 'Next page',
                        onPressed: _loading || _page + 1 >= _count
                            ? null
                            : () => _load(_page + 1),
                        icon: const Icon(Icons.chevron_right)),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
