import 'dart:async';
import 'dart:convert';

import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/protocol/json_rpc_client.dart';
import 'package:android_ssh_codex/src/protocol/rpc_transport.dart';
import 'package:android_ssh_codex/src/tasks/task_reducer.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Transport implements RpcTransport {
  final incoming = StreamController<String>();
  final outgoing = StreamController<Map<String, dynamic>>();
  late final requests = StreamIterator(outgoing.stream);

  @override
  Stream<String> get messages => incoming.stream;
  @override
  void send(String message) =>
      outgoing.add(jsonDecode(message) as Map<String, dynamic>);
  @override
  Future<void> close() async {
    if (!incoming.isClosed) await incoming.close();
  }

  Future<Map<String, dynamic>> next(String method) async {
    expect(
        await requests.moveNext().timeout(const Duration(seconds: 2)), isTrue);
    expect(requests.current['method'], method);
    return requests.current;
  }

  void reply(Map<String, dynamic> request, Map<String, dynamic> result) =>
      incoming.add(jsonEncode({'id': request['id'], 'result': result}));
  void fail(Map<String, dynamic> request) => incoming.add(jsonEncode({
        'id': request['id'],
        'error': {'code': -32000, 'message': 'read unavailable'}
      }));
  void notify(String method, Map<String, dynamic> params) =>
      incoming.add(jsonEncode({'method': method, 'params': params}));
}

Map<String, dynamic> page(List<(String, String)> items, {String? cursor}) => {
      'data': [
        for (final (id, text) in items.reversed)
          {
            'item': {'id': id, 'type': 'agentMessage', 'text': text}
          }
      ],
      'nextCursor': cursor,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Transport transport;
  late JsonRpcClient rpc;
  late AppController controller;
  setUp(() {
    transport = _Transport();
    rpc = JsonRpcClient(transport)..start();
    controller = AppController.connectedForTesting(rpc: rpc, cachedTasks: [
      TaskSnapshot(
          id: 'one',
          title: 'One',
          status: TaskStatus.running,
          cwd: '/repo',
          updatedAt: DateTime.utc(2026),
          items: const [
            TaskItem(id: 'a', kind: TaskItemKind.agent, text: 'Older context'),
            TaskItem(id: 'b', kind: TaskItemKind.agent, text: 'Cached partial'),
          ]),
    ]);
  });
  tearDown(() async {
    controller.dispose();
    await rpc.close();
    await transport.requests.cancel();
    await transport.outgoing.close();
  });

  test('cached task resumes before latest read and keeps chronological order',
      () async {
    final selecting = controller.selectTask('one');
    expect(controller.selectedTask!.items.last.text, 'Cached partial');
    final resume = await transport.next('thread/resume');
    expect(resume['params']['excludeTurns'], isTrue);
    transport.reply(resume, {});
    final read = await transport.next('thread/items/list');
    transport.reply(read,
        page([('b', 'Complete answer'), ('c', 'New reply')], cursor: 'older'));
    await selecting;
    expect(
        controller.selectedTask!.items.map((item) => item.id), ['a', 'b', 'c']);
    expect(controller.selectedTask!.items[1].text, 'Complete answer');
    expect(controller.hasOlderTaskContext, isTrue);

    final older = controller.loadOlderSelectedTaskContext();
    final olderRead = await transport.next('thread/items/list');
    expect(olderRead['params']['cursor'], 'older');
    transport.reply(
        olderRead, page([('a', 'Older context'), ('b', 'Stale partial')]));
    await older;
    expect(
        controller.selectedTask!.items.map((item) => item.id), ['a', 'b', 'c']);
    expect(controller.selectedTask!.items[1].text, 'Complete answer');

    final reopening = controller.selectTask('one');
    // No redundant resume on the same RPC session.
    transport.reply(await transport.next('thread/items/list'),
        page([('b', 'Revised'), ('c', 'New reply')]));
    await reopening;
    expect(controller.selectedTask!.items[1].text, 'Revised');
    transport.notify('item/agentMessage/delta',
        {'threadId': 'one', 'itemId': 'c', 'delta': ' streamed'});
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(controller.selectedTask!.items.last.text, 'New reply streamed');
  });

  test('in-flight snapshot cannot replace a newer completed item', () async {
    final selecting = controller.selectTask('one');
    transport.reply(await transport.next('thread/resume'), {});
    final read = await transport.next('thread/items/list');
    transport.notify('item/completed', {
      'threadId': 'one',
      'item': {
        'id': 'b',
        'type': 'agentMessage',
        'text': 'Final correction',
        'status': 'completed'
      }
    });
    transport.reply(read, page([('b', 'Stale snapshot')]));
    await selecting;
    expect(controller.selectedTask!.items.last.text, 'Final correction');
  });

  test('refresh failure retains cache and exposes a retryable error', () async {
    final selecting = controller.selectTask('one');
    transport.reply(await transport.next('thread/resume'), {});
    transport.fail(await transport.next('thread/items/list'));
    await selecting;
    expect(controller.selectedTask!.items.last.text, 'Cached partial');
    expect(controller.taskDetailError('one'), contains('read unavailable'));
    final retry = controller.retrySelectedTaskDetails();
    transport.reply(
        await transport.next('thread/items/list'), page([('b', 'Recovered')]));
    await retry;
    expect(controller.taskDetailError('one'), isNull);
    expect(controller.selectedTask!.items.last.text, 'Recovered');
  });

  test('failed subscription still reads history and retries subscription',
      () async {
    final selecting = controller.selectTask('one');
    transport.fail(await transport.next('thread/resume'));
    transport.reply(await transport.next('thread/items/list'),
        page([('b', 'Read-only latest')]));
    await selecting;
    expect(controller.selectedTask!.items.last.text, 'Read-only latest');
    expect(controller.taskDetailError('one'),
        contains('Live updates unavailable'));
    final retry = controller.retrySelectedTaskDetails();
    transport.reply(await transport.next('thread/resume'), {});
    transport.reply(
        await transport.next('thread/items/list'), page([('b', 'Subscribed')]));
    await retry;
    expect(controller.taskDetailError('one'), isNull);
  });

  test('overlapping opens share resume and reject an older history response',
      () async {
    final first = controller.selectTask('one');
    final resume = await transport.next('thread/resume');
    final second = controller.selectTask('one');
    transport.reply(resume, {});
    final oldRead = await transport.next('thread/items/list');
    final newRead = await transport.next('thread/items/list');
    transport.reply(newRead, page([('b', 'Newest')], cursor: 'new-cursor'));
    await second;
    transport.reply(
        oldRead, page([('b', 'Older response')], cursor: 'old-cursor'));
    await first;
    expect(controller.selectedTask!.items.last.text, 'Newest');
    final older = controller.loadOlderSelectedTaskContext();
    final request = await transport.next('thread/items/list');
    expect(request['params']['cursor'], 'new-cursor');
    transport.reply(request, page([]));
    await older;
  });
}
