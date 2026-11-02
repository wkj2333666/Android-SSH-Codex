import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:android_ssh_codex/src/transport/media_preview.dart';
import 'package:android_ssh_codex/src/transport/media_preview_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preview cache shares requests and bounds active helpers', () async {
    final cache = MediaPreviewCache();
    final gates = List.generate(4, (_) => Completer<Uint8List>());
    var started = 0;
    final first = cache.load('first', () {
      started++;
      return gates[0].future;
    });
    expect(
        identical(
            first, cache.load('first', () => throw StateError('duplicate'))),
        isTrue);
    final others = [
      for (var i = 1; i < gates.length; i++)
        cache.load('$i', () {
          started++;
          return gates[i].future;
        })
    ];
    expect(started, 2);
    gates[0].complete(Uint8List(1));
    await first;
    await pumpEventQueue();
    expect(started, 3);
    gates[1].complete(Uint8List(1));
    await pumpEventQueue();
    expect(started, 4);
    gates[2].complete(Uint8List(1));
    gates[3].complete(Uint8List(1));
    await Future.wait(others);
  });

  test('real video poster is a small JPEG and does not change the source',
      () async {
    final available = await Process.run('/bin/sh', ['-c', 'command -v ffmpeg']);
    if (available.exitCode != 0) {
      markTestSkipped('FFmpeg not installed');
      return;
    }
    final directory = await Directory.systemTemp.createTemp('video-poster-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/clip\'s sample.mp4');
    final generated = await Process.run('ffmpeg', [
      '-nostdin',
      '-v',
      'error',
      '-f',
      'lavfi',
      '-i',
      'color=c=red:s=1280x720:d=1',
      '-threads',
      '1',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      file.path
    ]);
    expect(generated.exitCode, 0, reason: '${generated.stderr}');
    final original = await file.readAsBytes();
    final result = await Process.run(
        '/bin/sh', ['-c', videoPosterCommand(file.path)],
        stdoutEncoding: null);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final bytes = result.stdout as List<int>;
    expect(bytes.take(2), [255, 216]);
    expect(bytes.length, lessThan(512 * 1024));
    expect(await file.readAsBytes(), original);
  });

  test('recovery reads only matching complete images in the exact rollout',
      () async {
    final directory = await Directory.systemTemp.createTemp('media-recovery-');
    addTearDown(() => directory.delete(recursive: true));
    final bytes = [
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
      ...List.generate(3000, (i) => i % 251)
    ];
    final data = base64Encode(bytes);
    final damaged =
        '${data.substring(0, 512)}…${data.length - 1024} chars truncated…${data.substring(data.length - 512)}';
    final file = File('${directory.path}/quoted\' rollout.jsonl');
    await file.writeAsString([
      jsonEncode({
        'type': 'session_meta',
        'payload': {'id': 'thread'}
      }),
      jsonEncode({
        'type': 'response_item',
        'payload': {
          'type': 'custom_tool_call_output',
          'output': [
            {'type': 'input_image', 'image_url': 'data:image/png;base64,$data'},
          ]
        }
      }),
    ].join('\n'));
    final result = await Process.run(
        '/bin/sh',
        [
          '-c',
          imageRecoveryCommand(
              file.path, 'thread', 'data:image/png;base64,$damaged')
        ],
        stdoutEncoding: null);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, bytes);
    final wrong = await Process.run('/bin/sh', [
      '-c',
      imageRecoveryCommand(
          file.path, 'other-thread', 'data:image/png;base64,$damaged')
    ]);
    expect(wrong.exitCode, isNot(0));
  });

  test('video poster command is bounded, local-only, and quotes paths', () {
    final encoded = videoPosterCommand("/tmp/clip'; touch nope; '.mp4");
    final command = utf8.decode(base64Decode(encoded.split("'")[3]));
    expect(command, contains('ffmpeg'));
    expect(command, contains('protocol_whitelist'));
    expect(command, contains('format_whitelist'));
    expect(command, contains('640'));
    expect(() => videoPosterCommand('https://example.com/clip.mp4'),
        throwsArgumentError);
  });
}
