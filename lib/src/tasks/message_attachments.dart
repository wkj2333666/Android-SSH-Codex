/// Presentation metadata only. The original prompt is never rewritten.
class MessageAttachment {
  const MessageAttachment({required this.path, this.name, this.isImage = false});

  final String path;
  final String? name;
  final bool isImage;

  String get label => name ?? path.split('/').last;
}

class AttachmentMessage {
  const AttachmentMessage(this.text, this.attachments);

  final String text;
  final List<MessageAttachment> attachments;
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
      if (paths.isNotEmpty &&
          paths.every((path) => path.startsWith('/') && path.trim() == path)) {
        attachments.addAll(paths.map(_attachment));
        body = text.substring(0, index).trimRight();
      }
    }
  }
  for (final attachment in native) {
    final index = attachments.indexWhere((a) => a.path == attachment.path);
    if (index < 0) {
      attachments.add(attachment);
    } else if (attachment.isImage) {
      attachments[index] = MessageAttachment(
        path: attachment.path,
        name: attachments[index].name,
        isImage: true,
      );
    }
  }
  return AttachmentMessage(body, attachments);
}

MessageAttachment _attachment(String path, {String? name}) => MessageAttachment(
      path: path,
      name: name,
      isImage: RegExp(r'\.(png|jpe?g|webp|gif)$', caseSensitive: false)
          .hasMatch(path),
    );
