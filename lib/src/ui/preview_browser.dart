import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// System WebView only; no JavaScript bridge is exposed to preview content.
abstract final class PreviewBrowser {
  static const channel = MethodChannel('android_ssh_codex/previews');

  static Future<bool> openPage(Uri uri) async {
    if (!{'http', 'https'}.contains(uri.scheme) ||
        uri.host != '127.0.0.1' || uri.userInfo.isNotEmpty ||
        uri.port < 1 || uri.port > 65535) {
      throw ArgumentError('Only forwarded loopback HTTP(S) pages can be previewed.');
    }
    try {
      return await channel.invokeMethod<bool>('openPage', {'url': uri.toString()}) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> openImage(Uint8List bytes, String label) async {
    Directory? temporary;
    try {
      final root = await channel.invokeMethod<String>('cacheDirectory');
      if (root == null) return false;
      temporary = await Directory(root).createTemp('codex-image-');
      final file = File('${temporary.path}/image');
      await file.writeAsBytes(bytes, flush: true);
      return await channel.invokeMethod<bool>('openImage', {
        'path': file.path, 'name': label,
      }) ?? false;
    } on MissingPluginException {
      return false;
    } finally {
      if (temporary != null) {
        try { await temporary.delete(recursive: true); } on FileSystemException { /* Cache cleanup is best effort. */ }
      }
    }
  }
}

Future<void> showImagePreview(BuildContext context, Uint8List bytes, {String label = 'Image'}) async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    try {
      if (await PreviewBrowser.openImage(bytes, label)) return;
    } on PlatformException {
      // A missing/disabled system WebView must not make images inaccessible.
    } on FileSystemException {
      // Fall back when the preview cache is unavailable.
    }
  }
  if (!context.mounted) return;
  await Navigator.of(context, rootNavigator: true).push<void>(MaterialPageRoute(
    builder: (_) => ImagePreviewPage(bytes: bytes, label: label),
  ));
}

/// Also used on platforms without the Android WebView preview.
class ImagePreviewPage extends StatefulWidget {
  const ImagePreviewPage({required this.bytes, required this.label, super.key});
  final Uint8List bytes;
  final String label;
  @override
  State<ImagePreviewPage> createState() => _ImagePreviewPageState();
}

class _ImagePreviewPageState extends State<ImagePreviewPage> {
  final _transform = TransformationController();
  Offset _tap = Offset.zero;
  void _zoom(double factor, Offset center) {
    final scale = _transform.value.getMaxScaleOnAxis();
    final target = (scale * factor).clamp(1.0, 8.0);
    final applied = target / scale;
    final matrix = Matrix4.identity()
      ..translate(center.dx, center.dy)
      ..scale(applied)
      ..translate(-center.dx, -center.dy);
    setState(() => _transform.value = matrix * _transform.value);
  }
  @override
  void dispose() { _transform.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(
    key: const Key('image-preview-page'),
    backgroundColor: Colors.black,
    appBar: AppBar(title: Text(widget.label), actions: [
      IconButton(tooltip: 'Zoom out', icon: const Icon(Icons.zoom_out), onPressed: () => _zoom(0.5, Offset.zero)),
      IconButton(tooltip: 'Zoom in', icon: const Icon(Icons.zoom_in), onPressed: () => _zoom(2, Offset.zero)),
      IconButton(tooltip: 'Reset zoom', icon: const Icon(Icons.fit_screen), onPressed: () => _transform.value = Matrix4.identity()),
    ]),
    body: LayoutBuilder(builder: (context, constraints) => GestureDetector(
      onDoubleTapDown: (details) => _tap = details.localPosition,
      onDoubleTap: () {
        if (_transform.value.getMaxScaleOnAxis() > 1) { _transform.value = Matrix4.identity(); }
        else { _zoom(2, _tap); }
      },
      child: InteractiveViewer(
        transformationController: _transform,
        maxScale: 8,
        child: SizedBox(width: constraints.maxWidth, height: constraints.maxHeight,
          child: Image.memory(widget.bytes, fit: BoxFit.contain, cacheWidth: 4096,
            errorBuilder: (_, __, ___) => const Center(child: Text('Image format is not supported.', style: TextStyle(color: Colors.white)))),
        ),
      ),
    )),
  );
}
