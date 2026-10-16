import 'package:android_ssh_codex/src/tasks/task_reducer.dart';
import 'package:flutter_test/flutter_test.dart';

TaskItem item(String id, [String? text]) =>
    TaskItem(id: id, kind: TaskItemKind.agent, text: text ?? id);

void main() {
  late TaskReducer reducer;
  late int epoch;
  setUp(() {
    reducer = TaskReducer();
    epoch = reducer.beginConnection();
  });
  List<TaskItem> items() => reducer.state.tasks['task']!.items;

  test(
      'fresh read replaces even longer cached text and preserves older history',
      () {
    reducer.replaceItems(
        epoch, 'task', [item('a'), item('b', 'A long cached draft')]);
    final token = reducer.captureItemsRead(epoch, 'task');
    reducer.mergeLatestItems(epoch, 'task', [item('b', 'A'), item('c')],
        readToken: token);
    expect(items().map((item) => item.id), ['a', 'b', 'c']);
    expect(items()[1].text, 'A');
  });

  test('older overlapping page never moves cached messages to the bottom', () {
    reducer.replaceItems(
        epoch, 'task', [item('a'), item('b'), item('c'), item('d')]);
    reducer.prependItems(epoch, 'task', [item('b'), item('c')]);
    expect(items().map((item) => item.id), ['a', 'b', 'c', 'd']);
    reducer.prependItems(epoch, 'task', [item('old'), item('a')]);
    expect(items().map((item) => item.id), ['old', 'a', 'b', 'c', 'd']);
  });

  test('latest read preserves concurrent events between snapshot anchors', () {
    reducer.replaceItems(epoch, 'task', [item('a'), item('b')]);
    final token = reducer.captureItemsRead(epoch, 'task');
    reducer.applyEvent(epoch, TaskEvent.itemChanged('task', item('live')));
    reducer.applyEvent(epoch, TaskEvent.itemChanged('task', item('c')));
    reducer.mergeLatestItems(epoch, 'task', [item('b'), item('c')],
        readToken: token);
    expect(items().map((item) => item.id), ['a', 'b', 'live', 'c']);
  });

  test('snapshot cannot rewind a streamed delta or completed tool event', () {
    reducer.replaceItems(epoch, 'task', [
      item('a', 'Hello'),
      const TaskItem(
          id: 'tool',
          kind: TaskItemKind.command,
          text: 'running',
          status: 'inProgress')
    ]);
    final token = reducer.captureItemsRead(epoch, 'task');
    reducer.applyEvent(
        epoch, const TaskEvent.agentDelta('task', 'a', null, ' world'));
    reducer.applyEvent(
        epoch,
        const TaskEvent.itemChanged(
            'task',
            TaskItem(
                id: 'tool',
                kind: TaskItemKind.command,
                text: 'done',
                status: 'completed')));
    reducer.mergeLatestItems(
        epoch,
        'task',
        [
          item('a', 'Hello'),
          const TaskItem(
              id: 'tool', kind: TaskItemKind.command, text: 'running')
        ],
        readToken: token);
    expect(items().first.text, 'Hello world');
    expect(items().last.status, 'completed');
  });

  test('two identical optimistic messages retain separate server identities',
      () {
    reducer.appendPendingUserMessage(epoch, 'task', 'local-1', 'again');
    reducer.appendPendingUserMessage(epoch, 'task', 'local-2', 'again');
    reducer.mergeLatestItems(epoch, 'task', const [
      TaskItem(id: 'server-1', kind: TaskItemKind.user, text: 'again'),
      TaskItem(id: 'server-2', kind: TaskItemKind.user, text: 'again'),
    ]);
    expect(items().map((item) => item.id), ['server-1', 'server-2']);
  });

  test('a snapshot from an old connection cannot alter retained cache', () {
    reducer.replaceItems(epoch, 'task', [item('a')]);
    final token = reducer.captureItemsRead(epoch, 'task');
    final nextEpoch = reducer.beginConnection(clearTasks: false);
    reducer.mergeLatestItems(nextEpoch, 'task', [item('b')], readToken: token);
    expect(items().single.id, 'a');
  });
}
