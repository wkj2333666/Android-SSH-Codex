import 'dart:convert';

import 'package:android_ssh_codex/src/tasks/message_attachments.dart';
import 'package:android_ssh_codex/src/tasks/task_reducer.dart';
import 'package:android_ssh_codex/src/ui/timeline_entries.dart';
import 'package:android_ssh_codex/src/ui/widgets/timeline_item.dart';
import 'package:android_ssh_codex/src/ui/widgets/remote_file_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=';

Future<void> _settleImage(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Markdown video preview plays on tap without a save picker',
      (tester) async {
    final played = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: RemoteFileActions(
      download: (_) async => throw StateError('Must not save for preview'),
      previewVideo: (path, {onProgress, onReady}) async {
        played.add(path);
        onReady?.call();
        return true;
      },
      child: const TimelineItemView(
          item: TaskItem(
              id: 'video',
              kind: TaskItemKind.agent,
              text: '![实验视频](/remote/experiment.mp4)')),
    ))));
    await tester.pumpAndSettle();
    expect(played, isEmpty);
    await tester.tap(find.text('Play video'));
    await tester.pumpAndSettle();
    expect(played, ['/remote/experiment.mp4']);
    expect(find.text('Download remote file?'), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('video Markdown image syntax does not load a video as an image',
      (tester) async {
    var reads = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: RemoteFileActions(
      download: (_) async => true,
      child: TimelineItemView(
        item: const TaskItem(
            id: 'video',
            kind: TaskItemKind.agent,
            text: '![Clip](/remote/clip.mp4)'),
        loadImage: (_) async {
          reads++;
          return base64Decode(_png);
        },
      ),
    ))));
    await tester.pumpAndSettle();
    expect(find.text('Download video'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(reads, 0);
    await tester.tap(find.text('Download video'));
    await tester.pumpAndSettle();
    expect(find.text('Download remote file?'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('videos have a video card and never request an image preview',
      (tester) async {
    var reads = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: TimelineItemView(
      item: const TaskItem(
          id: 'video',
          kind: TaskItemKind.user,
          text: 'Attached files (on the remote machine):\n'
              'Video file (video/mp4):\n/remote/clip',
          attachments: []),
      loadImage: (_) async {
        reads++;
        return base64Decode(_png);
      },
    ))));
    await tester.pumpAndSettle();
    expect(find.text('Video attachment'), findsOneWidget);
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(reads, 0);
    expect(tester.takeException(), isNull);
  });

  test('image-only messages are not filtered out of the timeline', () {
    expect(
        buildTimelineEntries(const [
          TaskItem(
              id: 'image',
              kind: TaskItemKind.agent,
              text: '',
              attachments: [
                MessageAttachment(
                    path: 'data:image/png;base64,$_png', isImage: true),
              ]),
        ]),
        hasLength(1));
  });

  testWidgets('tool images are visible while work events remain collapsed',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: TimelineActivityGroup(items: [
      TaskItem(
          id: 'tool',
          kind: TaskItemKind.tool,
          text: 'view image',
          detail: 'metadata',
          attachments: [
            MessageAttachment(
                path: 'data:image/png;base64,$_png',
                name: 'Tool image',
                isImage: true),
          ]),
    ]))));
    await _settleImage(tester);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('metadata'), findsNothing);
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('agent markdown remote images auto-preview without save dialogs',
      (tester) async {
    var reads = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: TimelineItemView(
      item: const TaskItem(
          id: 'agent',
          kind: TaskItemKind.agent,
          text: 'Camera:\n\n![Top camera](/remote/top%20camera.png)'),
      loadImage: (path) async {
        reads++;
        expect(path, '/remote/top camera.png');
        return base64Decode(_png);
      },
    ))));
    await _settleImage(tester);
    expect(reads, 1);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Download remote file?'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
