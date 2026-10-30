import 'dart:async';
import 'dart:convert';

import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/attachments.dart';
import 'package:android_ssh_codex/src/profiles/profile_store.dart';
import 'package:android_ssh_codex/src/protocol/codex_remote_api.dart';
import 'package:android_ssh_codex/src/protocol/json_rpc_client.dart';
import 'package:android_ssh_codex/src/protocol/rpc_transport.dart';
import 'package:android_ssh_codex/src/tasks/task_draft.dart';
import 'package:android_ssh_codex/src/tasks/task_message_queue.dart';
import 'package:android_ssh_codex/src/tasks/task_reducer.dart';
import 'package:android_ssh_codex/src/tasks/turn_settings.dart';
import 'package:flutter_test/flutter_test.dart';

class Transport implements RpcTransport {
  final input = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  final Set<String> withheldMethods = {};
  Map<String, dynamic> Function(Map<String, dynamic>)? handle;
  @override
  Stream<String> get messages => input.stream;
  @override
  void send(String value) {
    final request = (jsonDecode(value) as Map).cast<String, dynamic>();
    calls.add(request);
    if (withheldMethods.contains(request['method'])) return;
    final result = handle?.call(request) ?? <String, dynamic>{};
    if (request.containsKey('id')) {
      input.add(jsonEncode({'id': request['id'], 'result': result}));
    }
  }

  void notify(String method, Map<String, dynamic> params) =>
      input.add(jsonEncode({'method': method, 'params': params}));
  @override
  Future<void> close() async {
    if (!input.isClosed) await input.close();
  }
}

TaskSnapshot task() => TaskSnapshot(
    id: 'task',
    title: 'Test',
    status: TaskStatus.completed,
    cwd: '/repo',
    updatedAt: DateTime.utc(2026),
    items: const []);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('queued videos retain media metadata but never create image inputs',
      () async {
    final transport = Transport();
    final rpc = JsonRpcClient(transport)..start();
    final controller = AppController.connectedForTesting(
        rpc: rpc, cachedTasks: [task()]);
    await controller.selectTask('task');
    await controller.sendPrompt('Inspect',
        mode: TaskSendMode.queue,
        attachments: const [
          RemoteAttachment(
              path: '/remote/clip', isImage: true, mimeType: 'video/mp4'),
        ]);
    final pending = controller.queuedMessagesForTask('task').single;
    expect(pending.imagePaths, isEmpty);
    expect(pending.text, contains('Video file (video/mp4):\n/remote/clip'));
    controller.dispose();
    await rpc.close();
  });

  test('disposing before initialization does not erase saved drafts', () async {
    final store = MemoryProfileStore();
    await store.writeWorkspace({
      'drafts': ['existing state']
    });
    AppController(store: store).dispose();
    await Future<void>.delayed(Duration.zero);
    expect((await store.readWorkspace())['drafts'], ['existing state']);
  });

  test('timed-out submission is durable and refresh never resends it',
      () async {
    final store = MemoryProfileStore();
    final transport = Transport()..withheldMethods.add('turn/start');
    final rpc = JsonRpcClient(transport,
        requestTimeout: const Duration(milliseconds: 50))
      ..start();
    final controller = AppController.connectedForTesting(
        rpc: rpc, store: store, cachedTasks: [task()]);
    await controller.selectTask('task');
    await controller.sendPrompt('Do this once');
    final pending = controller.queuedMessagesForTask('task').single;
    expect(controller.deliveryState(pending.id), 'uncertain');
    final saved = await store.readWorkspace();
    expect((saved['outbox'] as List).single['state'], 'uncertain');
    await controller.refreshTasks();
    await Future<void>.delayed(Duration.zero);
    expect(
        transport.calls.where((call) => call['method'] == 'turn/start').length,
        1);
    controller.dispose();
    await rpc.close();
  });

  test('project change notifications refresh without waiting for timer polling',
      () async {
    final transport = Transport();
    final rpc = JsonRpcClient(transport)..start();
    final controller = AppController.connectedForTesting(rpc: rpc);
    transport.notify('project/changed', {});
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(transport.calls.any((call) => call['method'] == 'project/list'),
        isTrue);
    expect(
        transport.calls.any((call) => call['method'] == 'thread/list'), isTrue);
    controller.dispose();
    await rpc.close();
  });

  test('search, pin, fork and revert use bounded server operations', () async {
    final transport = Transport()
      ..handle = (call) => switch (call['method']) {
            'thread/list' => {'data': [], 'nextCursor': null},
            'thread/metadata/update' => {
                'thread': {'id': 'task', 'isPinned': true}
              },
            'thread/fork' => {
                'thread': {'id': 'fork', 'cwd': '/repo'}
              },
            _ => {},
          };
    final rpc = JsonRpcClient(transport)..start();
    final api = CodexRemoteApi(rpc);
    await api.readTaskPage(
        searchTerm: 'needle', archived: true, isPinned: true, cursor: 'next');
    expect(
        transport.calls.last['params'], containsPair('searchTerm', 'needle'));
    expect(transport.calls.last['params'], containsPair('limit', 20));
    await api.pinThread('task', true);
    expect((await api.forkThread('task', lastTurnId: 'turn')).id, 'fork');
    expect(transport.calls.last['params'],
        {'threadId': 'task', 'lastTurnId': 'turn', 'excludeTurns': true});
    await api.revertThread('task', 'turn');
    expect(transport.calls.last['params'],
        {'threadId': 'task', 'beforeTurnId': 'turn'});
    await rpc.close();
  });

  test('old servers must not silently pretend to pin tasks', () async {
    final transport = Transport();
    final rpc = JsonRpcClient(transport)..start();
    await expectLater(
        CodexRemoteApi(rpc).pinThread('task', true), throwsUnsupportedError);
    await rpc.close();
  });

  test(
      'goal status update preserves objective and usage; notifications refresh UI state',
      () async {
    final transport = Transport()
      ..handle = (call) => {
            if (call['method'] == 'thread/goal/set')
              'goal': {
                'objective': 'Keep going',
                'status': call['params']['status'],
                'tokensUsed': 100,
                'timeUsedSeconds': 12,
                'tokenBudget': 900,
              },
          };
    final rpc = JsonRpcClient(transport)..start();
    final controller =
        AppController.connectedForTesting(rpc: rpc, cachedTasks: [task()]);
    await controller.selectTask('task');
    await controller.setGoalPaused(true);
    expect(transport.calls.last['params'],
        {'threadId': 'task', 'status': 'paused', 'origin': 'user'});
    expect(controller.selectedGoal!.tokensUsed, 100);
    transport.notify('thread/goal/updated', {
      'threadId': 'task',
      'goal': {
        'objective': 'Keep going',
        'status': 'active',
        'tokensUsed': 150,
      }
    });
    await Future<void>.delayed(Duration.zero);
    expect(controller.selectedGoal!.tokensUsed, 150);
    transport.notify('thread/goal/cleared', {'threadId': 'task'});
    await Future<void>.delayed(Duration.zero);
    expect(controller.selectedGoal, isNull);
    controller.dispose();
    await rpc.close();
  });

  test('draft and queue survive disconnect and controller recreation',
      () async {
    final store = MemoryProfileStore();
    final transport = Transport();
    final rpc = JsonRpcClient(transport)..start();
    final first = AppController.connectedForTesting(
        rpc: rpc, store: store, cachedTasks: [task()]);
    await first.selectTask('task');
    await first.disconnect();
    final draft = first.draftForTask('task');
    draft.composer.text = 'Remember this draft';
    draft.settings = const TurnSettings(
        model: 'model', effort: 'high', serviceTier: 'priority');
    draft.changed();
    await first.sendPrompt('Send when connected', mode: TaskSendMode.queue);
    await first.flushWorkspace();
    expect(first.queuedMessagesForTask('task').length, 1);
    first.dispose();

    final secondRpc = JsonRpcClient(Transport())..start();
    final second = AppController.connectedForTesting(
        rpc: secondRpc, store: store, cachedTasks: [task()]);
    await second.initialize();
    expect(second.draftForTask('task').composer.text, 'Remember this draft');
    expect(second.draftForTask('task').settings.fast, isTrue);
    expect(second.queuedMessagesForTask('task').single.text,
        'Send when connected');
    second.dispose();
    await secondRpc.close();
  });

  test('in-flight messages restore as uncertain and remain scoped to host',
      () async {
    final store = MemoryProfileStore();
    await store.writeWorkspace({
      'outbox': [
        {
          'host': 'test',
          'task': 'task',
          'state': 'sending',
          'message':
              const QueuedTaskMessage(id: 'pending', text: 'Do work').toJson(),
        }
      ]
    });
    final rpc = JsonRpcClient(Transport())..start();
    final controller =
        AppController.connectedForTesting(rpc: rpc, store: store);
    await controller.initialize();
    expect(controller.deliveryState('pending'), 'uncertain');
    expect(controller.queuedMessagesForTask('task').length, 1);
    controller.dispose();
    await rpc.close();
    final otherRpc = JsonRpcClient(Transport())..start();
    final other = AppController.connectedForTesting(
        rpc: otherRpc, store: store, hostId: 'another');
    await other.initialize();
    expect(other.queuedMessagesForTask('task'), isEmpty);
    other.dispose();
    await otherRpc.close();
  });

  test('attachment restore retains upload token for resumable transfer', () {
    Future<RemoteAttachment> upload(attachment, target, cancellation,
            {onProgress}) async =>
        const RemoteAttachment(path: '/remote/file', isImage: false);
    final first = TaskDraft(
        upload: upload, canUpload: () => false, retainFilesOnDispose: true);
    first.addAttachment(const LocalAttachment(
        name: 'file', path: '/private/file', size: 12, isImage: false));
    final saved = first.toJson();
    final next = TaskDraft(
        upload: upload, canUpload: () => false, retainFilesOnDispose: true)
      ..restore(saved);
    expect(next.attachments.single.target.token,
        first.attachments.single.target.token);
    expect(next.attachments.single.state, AttachmentState.waiting);
    first.dispose();
    next.dispose();
  });
}
