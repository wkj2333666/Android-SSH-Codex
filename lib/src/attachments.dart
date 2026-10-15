import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LocalAttachment {
  const LocalAttachment(
      {required this.name,
      required this.path,
      required this.size,
      required this.isImage});

  final String name;
  final String path;
  final int size;
  final bool isImage;
}

class RemoteAttachment {
  const RemoteAttachment({required this.path, required this.isImage});

  final String path;
  final bool isImage;
}

abstract final class Attachments {
  static const channel = MethodChannel('android_ssh_codex/attachments');
  static const maxCount = 4;
  static const maxFileBytes = 1024 * 1024 * 1024;
  static const maxTotalBytes = maxFileBytes * maxCount;
  static const maxImagePreviewBytes = 10 * 1024 * 1024;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<LocalAttachment?> pick({required bool image}) async {
    final result = await channel.invokeMapMethod<String, dynamic>(
      'pick',
      {'image': image},
    );
    if (result == null) return null;
    final attachment = LocalAttachment(
      name: result['name'] as String,
      path: result['path'] as String,
      size: result['size'] as int,
      isImage: result['isImage'] == true,
    );
    validate([attachment]);
    return attachment;
  }

  static void validate(List<LocalAttachment> attachments) {
    if (attachments.length > maxCount ||
        attachments.any((file) =>
            file.size < 0 ||
            file.size > maxFileBytes ||
            file.path.isEmpty ||
            file.path.contains('\u0000')) ||
        attachments.fold<int>(0, (sum, file) => sum + file.size) >
            maxTotalBytes) {
      throw ArgumentError('Up to 4 attachments of 1 GiB each.');
    }
  }

  static Future<void> release(LocalAttachment attachment) async {
    try {
      final file = File(attachment.path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Cache cleanup is best effort; Android also reclaims cache files.
    }
  }

  static Future<void> releaseAll(Iterable<LocalAttachment> attachments) async {
    await Future.wait(attachments.map(release));
  }
}

String attachmentPrompt(String text, List<RemoteAttachment> attachments) => [
      if (text.trim().isNotEmpty) text.trim(),
      if (attachments.isNotEmpty) 'Attached files (on the remote machine):',
      for (final attachment in attachments) attachment.path,
    ].join('\n');
