import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../tasks/message_attachments.dart';
import 'remote_file_actions.dart';
import 'image_preview_data.dart';
export 'image_preview_data.dart' show loadPreviewImage;

Future<Uint8List> readMessageImage(
    MessageAttachment attachment,
    Future<Uint8List> Function(String)? loadImage,
    Future<Uint8List> Function(String)? recoverImage) async {
  final path = attachment.path;
  if (imageDataTruncated(path)) {
    if (recoverImage == null) throw StateError('Incomplete image history');
    return recoverImage(path);
  }
  if (!path.startsWith('data:')) {
    if (loadImage == null) throw StateError('Reconnect to load this image');
    return loadImage(path);
  }
  final match =
      RegExp(r'^data:image/(?:png|jpeg|webp|gif);base64,').firstMatch(path);
  if (match == null || path.length > 14 * 1024 * 1024) {
    throw const FormatException('Unsupported or oversized image');
  }
  return base64Decode(path.substring(match.end));
}

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

  Future<Uint8List> Function(String)? _recovery;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final recovery = RemoteFileActions.maybeOf(context)?.recoverImage;
    if (!_started || recovery != _recovery) {
      _started = true;
      _recovery = recovery;
      _preview = _load();
    }
  }

  @override
  void didUpdateWidget(InlineAttachmentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.path != widget.attachment.path) _preview = _load();
  }

  Future<Uint8List?> _load() => loadPreviewImage(
      readMessageImage(widget.attachment, widget.loadImage, _recovery));

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 280,
        height: 180,
        child: FutureBuilder<Uint8List?>(
          future: _preview,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final bytes = snapshot.data;
            if (bytes == null) {
              return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (imageDataTruncated(widget.attachment.path))
                      const Text(
                          'Historical image is incomplete and could not be restored.',
                          textAlign: TextAlign.center),
                    TextButton.icon(
                      onPressed: () => setState(() {
                        _preview = _load();
                      }),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Image unavailable · Retry'),
                    ),
                  ]);
            }
            return InkWell(
              onTap: () => showDialog<void>(
                context: context,
                builder: (context) => Dialog(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: InteractiveViewer(
                          child: Image.memory(bytes,
                              cacheWidth: 1200,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) =>
                                  const Text('Image format is not supported.')),
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ),
              ),
              child: Image.memory(bytes,
                  cacheWidth: 560,
                  fit: BoxFit.contain,
                  semanticLabel: widget.attachment.label,
                  errorBuilder: (_, __, ___) => const Center(
                      child: Text('Image format is not supported.'))),
            );
          },
        ),
      );
}
