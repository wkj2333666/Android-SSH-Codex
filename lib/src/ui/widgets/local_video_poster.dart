import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../attachments.dart';
import 'image_preview_data.dart';

class LocalVideoPoster extends StatefulWidget {
  const LocalVideoPoster({required this.path, super.key});
  final String path;
  @override
  State<LocalVideoPoster> createState() => _LocalVideoPosterState();
}

class _LocalVideoPosterState extends State<LocalVideoPoster> {
  late Future<Uint8List?> _future;
  Future<Uint8List?> _load() => loadPreviewImage(Future.sync(() async {
    final bytes = await Attachments.channel.invokeMethod<Uint8List>('videoThumbnail', {'path': widget.path});
    if (bytes == null) throw StateError('No video cover');
    return bytes;
  }), maxBytes: 512 * 1024, maxDimension: 640, maxPixels: 640 * 640);
  @override
  void initState() { super.initState(); _future = _load(); }
  @override
  void didUpdateWidget(LocalVideoPoster oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _future = _load();
  }
  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(future: _future, builder: (context, snapshot) {
    final bytes = snapshot.data;
    return bytes == null ? const Icon(Icons.videocam_outlined) : Image.memory(bytes, fit: BoxFit.cover, cacheWidth: 64);
  });
}
