import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LocalAttachment {
  const LocalAttachment({required this.name, required this.bytes, required this.isImage});

  final String name;
  final Uint8List bytes;
  final bool isImage;
}

class RemoteAttachment {
  const RemoteAttachment({required this.path, required this.isImage});

  final String path;
  final bool isImage;
}

abstract final class Attachments {
  static const channel = MethodChannel('android_ssh_codex/attachments');
  static const maxFileBytes = 10 * 1024 * 1024;
  static const maxTotalBytes = 20 * 1024 * 1024;
  static const maxCount = 4;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<LocalAttachment?> pick({required bool image}) async {
    final result = await channel.invokeMapMethod<String, dynamic>(
      'pick', {'image': image},
    );
    if (result == null) return null;
    final attachment = LocalAttachment(
      name: result['name'] as String,
      bytes: result['bytes'] as Uint8List,
      isImage: result['isImage'] == true,
    );
    validate([attachment]);
    return attachment;
  }

  static void validate(List<LocalAttachment> attachments) {
    if (attachments.length > maxCount ||
        attachments.any((file) => file.bytes.length > maxFileBytes) ||
        attachments.fold<int>(0, (sum, file) => sum + file.bytes.length) > maxTotalBytes) {
      throw ArgumentError('Up to 4 attachments, 10 MiB each and 20 MiB total.');
    }
  }
}

String attachmentPrompt(String text, List<RemoteAttachment> attachments) => [
      if (text.trim().isNotEmpty) text.trim(),
      if (attachments.isNotEmpty) 'Attached files (on the remote machine):',
      for (final attachment in attachments) attachment.path,
    ].join('\n');
