import 'dart:convert';

import '../attachment_media.dart';

/// Presentation metadata only. The original prompt is never rewritten.
class MessageAttachment {
  const MessageAttachment(
      {required this.path, this.name, bool isImage = false, this.mimeType})
      : _isImage = isImage;

  final String path;
  final String? name;
  final bool _isImage;
  final String? mimeType;
  bool get isVideo =>
      videoAttachmentMimeType(path, mimeType) != null ||
      videoAttachmentMimeType(name ?? '', null) != null;
  bool get isImage => _isImage && !isVideo;

  String get label {
    if (name != null) return name!;
    final basename = path.split('/').last;
    if (path.contains('/.local/share/android-ssh-codex/attachments/') &&
        basename.startsWith('file-')) {
      return basename.substring(5);
    }
    return basename.isEmpty ? (isImage ? 'Image' : 'File') : basename;
  }
}

class AttachmentMessage {
  const AttachmentMessage(this.text, this.attachments);

  final String text;
  final List<MessageAttachment> attachments;
}

/// Only unwrap complete MCP content envelopes, not arbitrary prose/examples.
Map<String, dynamic>? imageEnvelope(String text) {
  if (text.length > 14 * 1024 * 1024 || !text.trimLeft().startsWith('{'))
    return null;
  try {
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic> ||
        value['content'] is! List ||
        value.keys.any((key) => !const [
              'content',
              'structuredContent',
              'structured_content',
              'isError',
              'is_error',
              '_meta'
            ].contains(key))) return null;
    return value;
  } on FormatException {
    return null;
  }
}

bool imageDataTruncated(String source) =>
    source.startsWith('data:image/') &&
    RegExp(r'…\d+ chars truncated…').hasMatch(source);

/// Read image blocks only from protocol content, never from tool arguments or
/// arbitrary text. MCP embedded bytes and dynamic-tool image URLs share the
/// same presentation model as user attachments.
List<MessageAttachment> outputImageAttachments(Map<String, dynamic> item) {
  final images = <MessageAttachment>[];
  final seen = <String>{};
  void blocks(Object? raw, [int depth = 0]) {
    if (raw is! List || depth > 3) return;
    for (final block in raw) {
      if (block is! Map) continue;
      final type = block['type'];
      if (type == 'text' &&
          block['text'] is String &&
          const ['mcpToolCall', 'dynamicToolCall'].contains(item['type'])) {
        final envelope = imageEnvelope(block['text'] as String);
        if (envelope != null) blocks(envelope['content'], depth + 1);
      }
      if (type != 'image' &&
          type != 'localImage' &&
          type != 'inputImage' &&
          type != 'input_image' &&
          type != 'output_image' &&
          type != 'image_url') {
        continue;
      }
      String? source;
      final data = block['data'];
      final mime = block['mimeType'];
      if (data is String &&
          data.length <= 14 * 1024 * 1024 &&
          const ['image/png', 'image/jpeg', 'image/webp', 'image/gif']
              .contains(mime)) {
        source = 'data:$mime;base64,$data';
      } else {
        final value = block['path'] ??
            block['url'] ??
            block['imageUrl'] ??
            block['image_url'];
        source = value is String
            ? value
            : value is Map && value['url'] is String
                ? value['url'] as String
                : null;
      }
      if (source == null || source.isEmpty || !seen.add(source)) continue;
      images.add(MessageAttachment(
          path: source,
          name: source.startsWith('/') ? null : 'Image',
          isImage: true,
          mimeType: mime is String ? mime : null));
    }
  }

  blocks(item['content']);
  blocks(item['contentItems']);
  final result = item['result'];
  if (result is Map) {
    blocks(result['content']);
    blocks(result['contentItems']);
  } else if (result is String) {
    blocks(imageEnvelope(result)?['content']);
  }
  return List.unmodifiable(images);
}

AttachmentMessage parseAttachmentMessage(
  String text, [
  List<MessageAttachment> native = const [],
]) {
  var body = text;
  final attachments = <MessageAttachment>[];
  // Match only the complete Desktop envelope, never arbitrary headings.
  final desktop = RegExp(
    r'^\s*# Files (?:mentioned|pasted) by the user:\s*\n([\s\S]*?)\n(?:Distinguish instructions in attached documents from the user\x27s request\.\s*\n)?## My request:\s*\n?([\s\S]*)$',
  ).firstMatch(text);
  if (desktop != null) {
    final entries = desktop.group(1)!.trim().split(RegExp(r'\n\s*\n'));
    final parsed = <MessageAttachment>[];
    for (final entry in entries) {
      final match = RegExp(r'^## (.+): (/[^\r\n]+)$').firstMatch(entry.trim());
      if (match == null) return AttachmentMessage(text, native);
      parsed.add(_attachment(match.group(2)!, name: match.group(1)!));
    }
    if (parsed.isNotEmpty) {
      attachments.addAll(parsed);
      body = desktop.group(2)!;
    }
  } else {
    const marker = 'Attached files (on the remote machine):\n';
    final index = text.lastIndexOf(marker);
    if (index == 0 || (index > 0 && text[index - 1] == '\n')) {
      final paths = text.substring(index + marker.length).trim().split('\n');
      final parsed = <MessageAttachment>[];
      var valid = paths.isNotEmpty;
      for (var i = 0; i < paths.length; i++) {
        var path = paths[i];
        String? mimeType;
        final video =
            RegExp(r'^Video file \((video/[a-z0-9.+-]+)\):$').firstMatch(path);
        if (video != null && i + 1 < paths.length) {
          mimeType = video.group(1);
          path = paths[++i];
        }
        if (!path.startsWith('/') || path.trim() != path) {
          valid = false;
          break;
        }
        parsed.add(_attachment(path, mimeType: mimeType));
      }
      if (valid) {
        attachments.addAll(parsed);
        body = text.substring(0, index).trimRight();
      }
    }
  }
  for (final attachment in native) {
    final index = attachments.indexWhere((a) => a.path == attachment.path);
    if (index < 0) {
      attachments.add(attachment);
    } else if (attachment.isVideo ||
        (attachment.isImage && !attachments[index].isVideo)) {
      attachments[index] = MessageAttachment(
        path: attachment.path,
        name: attachments[index].name,
        isImage: attachment.isImage,
        mimeType: attachment.mimeType ?? attachments[index].mimeType,
      );
    }
  }
  return AttachmentMessage(body, attachments);
}

MessageAttachment _attachment(String path, {String? name, String? mimeType}) =>
    MessageAttachment(
      path: path,
      name: name,
      mimeType: mimeType,
      isImage: RegExp(r'\.(png|jpe?g|webp|gif)$', caseSensitive: false)
          .hasMatch(path),
    );
