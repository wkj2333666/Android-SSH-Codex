/// Video inputs are remote files, never native Codex image inputs. MIME data
/// from a document provider must survive caching, where paths end in `.bin`.
String? videoAttachmentMimeType(String name, String? mimeType) {
  final declared = mimeType?.split(';').first.trim().toLowerCase();
  if (declared != null && RegExp(r'^video/[a-z0-9.+-]+$').hasMatch(declared)) {
    return declared;
  }
  // Embedded image URLs can contain megabytes of Base64. Never split or
  // lowercase their payload just to classify a filename extension.
  if (name.startsWith('data:')) return null;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || name.length - dot > 6) return null;
  final extension = name.substring(dot + 1).toLowerCase();
  return const {
    'mp4': 'video/mp4',
    'm4v': 'video/x-m4v',
    'mov': 'video/quicktime',
    'webm': 'video/webm',
    'mkv': 'video/x-matroska',
    'avi': 'video/x-msvideo',
    'mpeg': 'video/mpeg',
    'mpg': 'video/mpeg',
    '3gp': 'video/3gpp',
    '3g2': 'video/3gpp2',
    'ogv': 'video/ogg',
    'wmv': 'video/x-ms-wmv',
    'flv': 'video/x-flv',
    'm2ts': 'video/mp2t',
  }[extension];
}
