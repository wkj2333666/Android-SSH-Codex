import 'dart:async';
import 'dart:convert';
import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/protocol/json_rpc_client.dart';
import 'package:android_ssh_codex/src/protocol/rpc_transport.dart';
import 'package:android_ssh_codex/src/ui/tasks_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _workspace =
    '/home/user/.local/share/android-ssh-codex/workspaces/session.Abc123Xyz456';

class _Transport implements RpcTransport {
  final input = StreamController<String>();
  final requests = <Map>[];
  @override
  Stream<String> get messages => input.stream;
  @override
  void send(String text) {
    final request = jsonDecode(text) as Map;
    requests.add(request);
    if (request['id'] == null) return;
    input.add(jsonEncode({
      'id': request['id'],
      'result': request['method'] == 'thread/start'
          ? {
              'thread': {'id': 'standalone', 'cwd': _workspace}
            }
          : {'data': []}
    }));
  }

  @override
  Future<void> close() => input.close();
}

void main() {
  testWidgets(
      'blank directory starts in a new anonymous workspace without a project',
      (tester) async {
    final transport = _Transport();
    late JsonRpcClient rpc;
    late AppController controller;
    var allocations = 0;
    await tester.runAsync(() async {
      rpc = JsonRpcClient(transport)..start();
      controller = AppController.connectedForTesting(
        rpc: rpc,
        createAnonymousWorkspace: () async {
          expect(transport.requests, isEmpty);
          allocations++;
          return _workspace;
        },
      );
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: TasksWorkspace(controller: controller))));
    await tester.tap(find.byTooltip('New task'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a task message.'), findsOneWidget);
    expect(transport.requests, isEmpty);
    expect(allocations, 0);
    await tester.enterText(find.byKey(const Key('new-task-prompt')), 'Hello');
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    final start =
        transport.requests.singleWhere((r) => r['method'] == 'thread/start');
    expect(allocations, 1);
    expect(start['params'], {'cwd': _workspace});
    expect(transport.requests.where((r) => r['method'] == 'turn/start'),
        hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      controller.dispose();
      await rpc.close();
    });
  }, timeout: const Timeout(Duration(seconds: 45)));
}
