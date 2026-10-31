import 'dart:typed_data';
import 'dart:ui' as ui;

Future<Uint8List?> loadPreviewImage(Future<Uint8List> loading,
    {int maxBytes = 10 * 1024 * 1024, int maxDimension = 16384, int maxPixels = 64 * 1024 * 1024}) async {
  try {
    final bytes = await loading;
    if (bytes.length > maxBytes) throw StateError('Image too large');
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        if (descriptor.width > maxDimension || descriptor.height > maxDimension || descriptor.width * descriptor.height > maxPixels) throw StateError('Image dimensions too large');
      } finally { descriptor.dispose(); }
    } finally { buffer.dispose(); }
    return bytes;
  } catch (_) { return null; }
}
