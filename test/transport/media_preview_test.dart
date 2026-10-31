import 'dart:convert';
import 'dart:io';

import 'package:android_ssh_codex/src/transport/media_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recovery reads only matching complete images in the exact rollout', () async {
    final directory = await Directory.systemTemp.createTemp('media-recovery-');
    addTearDown(() => directory.delete(recursive: true));
    final bytes = [137, 80, 78, 71, 13, 10, 26, 10, ...List.generate(3000, (i) => i % 251)];
    final data = base64Encode(bytes);
    final damaged = '${data.substring(0, 512)}…${data.length - 1024} chars truncated…${data.substring(data.length - 512)}';
    final file = File('${directory.path}/quoted\' rollout.jsonl');
    await file.writeAsString([
      jsonEncode({'type': 'session_meta', 'payload': {'id': 'thread'}}),
      jsonEncode({'type': 'response_item', 'payload': {'type': 'custom_tool_call_output', 'output': [
        {'type': 'input_image', 'image_url': 'data:image/png;base64,$data'},
      ]}}),
    ].join('\n'));
    final result = await Process.run('/bin/sh', ['-c', imageRecoveryCommand(file.path, 'thread', 'data:image/png;base64,$damaged')], stdoutEncoding: null);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, bytes);
    final wrong = await Process.run('/bin/sh', ['-c', imageRecoveryCommand(file.path, 'other-thread', 'data:image/png;base64,$damaged')]);
    expect(wrong.exitCode, isNot(0));
  });

  test('video poster command is bounded, local-only, and quotes paths', () {
    final command = videoPosterCommand("/tmp/clip'; touch nope; '.mp4");
    expect(command, contains('ffmpeg'));
    expect(command, contains('protocol_whitelist'));
    expect(command, contains('format_whitelist'));
    expect(command, contains('640'));
    expect(() => videoPosterCommand('https://example.com/clip.mp4'), throwsArgumentError);
  });
}
