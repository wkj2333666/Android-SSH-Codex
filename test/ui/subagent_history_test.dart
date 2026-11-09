import 'dart:async';
import 'dart:convert';

import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/protocol/json_rpc_client.dart';
import 'package:android_ssh_codex/src/protocol/rpc_transport.dart';
import 'package:android_ssh_codex/src/tasks/task_reducer.dart';
import 'package:android_ssh_codex/src/ui/task_view.dart';
import 'package:android_ssh_codex/src/ui/widgets/markdown_content.dart';
import 'package:android_ssh_codex/src/ui/widgets/timeline_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements RpcTransport {
  final input = StreamController<String>();
  final requests = <Map<String, dynamic>>[];

  @override
  Stream<String> get messages => input.stream;

  @override
  void send(String message) {
    final request = jsonDecode(message) as Map<String, dynamic>;
    requests.add(request);
    final result = switch (request['method']) {
      'thread/read' => {
          'thread': {'id': 'child', 'agentNickname': 'Sage'},
        },
      'thread/items/list' => {
          'data': [
            {
              'turnId': 'turn',
              'item': {
                'id': 'reply',
                'type': 'agentMessage',
                'text': 'Child result',
              },
            },
          ],
        },
      _ => <String, dynamic>{},
    };
    input.add(jsonEncode({'id': request['id'], 'result': result}));
  }

  @override
  Future<void> close() => input.close();
}

void main() {
  testWidgets('each subagent is directly tappable with work events collapsed',
      (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TimelineActivityGroup(
          items: const [
            TaskItem(
              id: 'spawn',
              kind: TaskItemKind.tool,
              text: '',
              subagents: [
                SubagentReference('a', path: '/root/reviewer'),
                SubagentReference('b', path: '/root/worker', status: 'running'),
              ],
            ),
            TaskItem(
              id: 'wait',
              kind: TaskItemKind.tool,
              text: '',
              subagents: [SubagentReference('a', status: 'completed')],
            ),
          ],
          onOpenSubagent: (agent) => opened.add(agent.threadId),
        ),
      ),
    ));

    expect(find.byKey(const Key('activity-viewport')), findsNothing);
    expect(find.text('reviewer · Completed'), findsOneWidget);
    await tester.tap(find.text('worker · Running'));
    await tester.tap(find.text('reviewer · Completed'));
    expect(opened, ['b', 'a']);
    expect(find.byKey(const Key('activity-viewport')), findsNothing);
  });

  testWidgets('opening a subagent reads history and preserves the parent draft',
      (tester) async {
    final transport = _Transport();
    late JsonRpcClient rpc;
    late AppController controller;
    await tester.runAsync(() async {
      rpc = JsonRpcClient(transport)..start();
      controller = AppController.connectedForTesting(rpc: rpc);
    });
    final task = TaskRecord.placeholder('parent', 0).copyWith(items: const [
      TaskItem(
        id: 'spawn',
        kind: TaskItemKind.tool,
        title: 'Subagent started',
        text: '',
        subagents: [SubagentReference('child', path: '/root/reviewer')],
      ),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TaskView(controller: controller, task: task)),
    ));
    controller.draftForTask('parent').composer.text = 'Unsent parent message';
    await tester.pump();
    await tester.tap(find.text('reviewer'));
    await tester.pump();
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(find.text('Sage'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(
      find.byWidgetPredicate((widget) =>
          widget is MarkdownContent && widget.text == 'Child result'),
      findsOneWidget,
    );
    expect(transport.requests.map((request) => request['method']), [
      'thread/read',
      'thread/items/list',
    ]);
    expect(transport.requests.last['params']['threadId'], 'child');
    expect(transport.requests.last['params']['limit'], 20);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Unsent parent message'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      controller.dispose();
      await rpc.close();
    });
  }, timeout: const Timeout(Duration(seconds: 45)));
}
