import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../tasks/message_attachments.dart';
import '../preview_browser.dart';

class ImagePreviewScope extends InheritedWidget {
  const ImagePreviewScope(
      {required this.loadImage, required super.child, super.key});

  final Future<Uint8List> Function(String)? loadImage;

  static Future<Uint8List> Function(String)? maybeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ImagePreviewScope>()
          ?.loadImage;

  @override
  bool updateShouldNotify(ImagePreviewScope oldWidget) =>
      loadImage != oldWidget.loadImage;
}

class InlineAttachmentImage extends StatefulWidget {
  const InlineAttachmentImage({
    required this.attachment,
    required this.loadImage,
    super.key,
  });

  final MessageAttachment attachment;
  final Future<Uint8List> Function(String)? loadImage;

  @override
  State<InlineAttachmentImage> createState() => InlineAttachmentImageState();
}

class InlineAttachmentImageState extends State<InlineAttachmentImage> {
  late Future<Uint8List?> _preview;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _preview = _load();
  }

  @override
  void didUpdateWidget(InlineAttachmentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.path != widget.attachment.path ||
        (oldWidget.loadImage == null && widget.loadImage != null)) _preview = _load();
  }

  Future<Uint8List?> _load() => loadAttachmentPreview(widget.attachment, widget.loadImage);

  Future<void> _open(Uint8List bytes) async {
    if (_opening) return;
    _opening = true;
    try { await showImagePreview(context, bytes, label: widget.attachment.label); }
    finally { _opening = false; }
  }

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 280),
        child: FutureBuilder<Uint8List?>(
          future: _preview,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(width: 280, height: 120,
                child: Center(child: CircularProgressIndicator()));
            }
            final bytes = snapshot.data;
            if (bytes == null) {
              return TextButton.icon(
                onPressed: () => setState(() { _preview = _load(); }),
                icon: const Icon(Icons.refresh),
                label: const Text('Image unavailable · Retry'),
              );
            }
            return InkWell(
              onTap: () => _open(bytes),
              child: Image.memory(bytes,
                  width: 480,
                  cacheWidth: 960,
                  fit: BoxFit.contain,
                  semanticLabel: widget.attachment.label,
                  errorBuilder: (_, __, ___) => const Center(
                      child: Text('Image format is not supported.'))),
            );
          },
        ),
      );
}

Future<Uint8List?> loadAttachmentPreview(MessageAttachment attachment,
    Future<Uint8List> Function(String)? loadImage) => loadPreviewImage(Future.sync(() {
        final path = attachment.path;
        if (!path.startsWith('data:')) {
          if (loadImage == null) throw StateError('Image loader unavailable');
          return loadImage(path);
        }
        final match = RegExp(r'^data:image/(?:png|jpeg|webp|gif);base64,')
            .firstMatch(path);
        if (match == null || path.length > 14 * 1024 * 1024) {
          throw const FormatException('Unsupported or oversized image');
        }
        return base64Decode(path.substring(match.end));
      }));

Future<Uint8List?> loadPreviewImage(Future<Uint8List> loading) async {
  try {
    return await _validatePreviewImage(await loading);
  } catch (_) {
    return null;
  }
}

Future<Uint8List> _validatePreviewImage(Uint8List bytes) async {
  if (bytes.length > 10 * 1024 * 1024) throw StateError('Image too large');
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (descriptor.width > 16384 ||
          descriptor.height > 16384 ||
          descriptor.width * descriptor.height > 64 * 1024 * 1024) {
        throw StateError('Image dimensions too large');
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
  return bytes;
}
