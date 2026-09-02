import 'package:android_ssh_codex/src/tasks/task_reducer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late TaskReducer reducer;

  setUp(() => reducer = TaskReducer());

  TaskSnapshot snapshot(
    String id, {
    TaskStatus status = TaskStatus.completed,
    String text = '',
  }) =>
      TaskSnapshot(
        id: id,
        title: 'Task $id',
        status: status,
        cwd: '/repo',
        updatedAt: DateTime.utc(2026, 7, 31),
        items: text.isEmpty
            ? const []
            : [TaskItem(id: 'message', kind: TaskItemKind.agent, text: text)],
      );

  test('discards a refresh from an older connection epoch', () {
    final firstEpoch = reducer.beginConnection();
    final token = reducer.beginRefresh(firstEpoch);
    reducer.beginConnection();

    reducer.applyRefresh(token, [snapshot('old')], const {});

    expect(reducer.state.tasks, isEmpty);
  });

  test('a new connection does not retain tasks from the previous host', () {
    final firstEpoch = reducer.beginConnection();
    final firstRefresh = reducer.beginRefresh(firstEpoch);
    reducer.applyRefresh(firstRefresh, [snapshot('host-a-task')], const {});

    reducer.beginConnection();

    expect(reducer.state.tasks, isEmpty);
  });

  test('a reconnect can retain stale tasks until its first refresh', () {
    final epoch = reducer.beginConnection();
    final refresh = reducer.beginRefresh(epoch);
    reducer.applyRefresh(refresh, [snapshot('retained')], const {});

    reducer.beginConnection(clearTasks: false);

    expect(reducer.state.tasks.keys, ['retained']);
  });

  test('discards an older overlapping refresh generation', () {
    final epoch = reducer.beginConnection();
    final older = reducer.beginRefresh(epoch);
    final newer = reducer.beginRefresh(epoch);
    reducer.applyRefresh(newer, [snapshot('new')], const {});
    reducer.applyRefresh(older, [snapshot('old')], const {});

    expect(reducer.state.tasks.keys, ['new']);
  });

  test('does not let a late snapshot overwrite a newer live event', () {
    final epoch = reducer.beginConnection();
    final token = reducer.beginRefresh(epoch);
    reducer.applyEvent(
      epoch,
      const TaskEvent.statusChanged('one', TaskStatus.running),
    );

    reducer.applyRefresh(
      token,
      [snapshot('one', status: TaskStatus.completed)],
      const {'one'},
    );

    expect(reducer.state.tasks['one']?.status, TaskStatus.running);
  });

  test('a captured page merge preserves events received during its request',
      () {
    final epoch = reducer.beginConnection();
    final initial = reducer.beginRefresh(epoch);
    reducer.applyRefresh(
      initial,
      [snapshot('one', status: TaskStatus.completed)],
      const {},
    );
    final page = reducer.capturePageMerge(epoch);

    reducer.applyEvent(
      epoch,
      const TaskEvent.statusChanged('one', TaskStatus.running),
    );
    final applied = reducer.applyPageMerge(
      page,
      [snapshot('one', status: TaskStatus.completed)],
      const {'one'},
    );

    expect(applied, isTrue);
    expect(reducer.state.tasks['one']?.status, TaskStatus.running);
  });

  test('a captured page merge expires on a new connection', () {
    final epoch = reducer.beginConnection();
    final page = reducer.capturePageMerge(epoch);

    reducer.beginConnection();
    final applied = reducer.applyPageMerge(
      page,
      [snapshot('stale-page')],
      const {},
    );

    expect(applied, isFalse);
    expect(reducer.state.tasks, isEmpty);
  });

  test('list snapshots with empty turns preserve cached task detail', () {
    final epoch = reducer.beginConnection();
    final detail = reducer.beginRefresh(epoch);
    reducer.applyRefresh(
      detail,
      [snapshot('one', text: 'Full history')],
      const {},
    );

    final listRefresh = reducer.beginRefresh(epoch);
    reducer.applyRefresh(listRefresh, [snapshot('one')], const {});

    expect(reducer.state.tasks['one']?.items.single.text, 'Full history');
  });

  test('detail hydration updates one task without dropping list siblings', () {
    final epoch = reducer.beginConnection();
    final token = reducer.beginRefresh(epoch);
    reducer.applyRefresh(token, [snapshot('one'), snapshot('two')], const {});

    reducer.applySnapshot(
      epoch,
      snapshot('one', text: 'Full history'),
      const {},
    );

    expect(reducer.state.tasks.keys, containsAll(['one', 'two']));
    expect(reducer.state.tasks['one']?.items.single.text, 'Full history');
  });

  test(
    'a head refresh can retain tasks from explicitly loaded older pages',
    () {
      final epoch = reducer.beginConnection();
      final first = reducer.beginRefresh(epoch);
      reducer.applyRefresh(first, [snapshot('older')], const {});

      final head = reducer.beginRefresh(epoch);
      reducer.applyRefresh(
        head,
        [snapshot('newer')],
        const {},
        retainExisting: true,
      );

      expect(reducer.state.tasks.keys, containsAll(['newer', 'older']));
    },
  );

  test('marks an active task loaded elsewhere as read-only', () {
    final epoch = reducer.beginConnection();
    final token = reducer.beginRefresh(epoch);

    reducer.applyRefresh(
      token,
      [snapshot('external', status: TaskStatus.running)],
      const {'mine'},
    );

    final task = reducer.state.tasks['external']!;
    expect(task.ownership, TaskOwnership.external);
    expect(task.canWrite, isFalse);
  });

  test('a completed external turn becomes writable without waiting for refresh',
      () {
    final epoch = reducer.beginConnection();
    final token = reducer.beginRefresh(epoch);
    reducer.applyRefresh(
      token,
      [snapshot('external', status: TaskStatus.running)],
      const {},
    );

    reducer.applyEvent(
      epoch,
      const TaskEvent.statusChanged('external', TaskStatus.completed),
    );

    expect(reducer.state.tasks['external']?.ownership, TaskOwnership.available);
    expect(reducer.state.tasks['external']?.canWrite, isTrue);
  });

  test('marks an active task loaded by this app-server as interactive', () {
    final epoch = reducer.beginConnection();
    final token = reducer.beginRefresh(epoch);

    reducer.applyRefresh(
      token,
      [snapshot('mine', status: TaskStatus.running)],
      const {'mine'},
    );

    expect(reducer.state.tasks['mine']?.ownership, TaskOwnership.local);
    expect(reducer.state.tasks['mine']?.canWrite, isTrue);
  });

  test('deduplicates streamed deltas by event id', () {
    final epoch = reducer.beginConnection();
    reducer.applyEvent(
      epoch,
      const TaskEvent.agentDelta('one', 'message', 'event-1', 'Hello'),
    );
    reducer.applyEvent(
      epoch,
      const TaskEvent.agentDelta('one', 'message', 'event-1', 'Hello'),
    );

    expect(reducer.state.tasks['one']?.items.single.text, 'Hello');
  });

  test('applies a batch of streamed deltas with one state revision', () {
    final epoch = reducer.beginConnection();

    reducer.applyEvents(
      epoch,
      const [
        TaskEvent.agentDelta('one', 'message', 'event-1', 'Hello'),
        TaskEvent.agentDelta('one', 'message', 'event-2', ' world'),
      ],
    );

    expect(reducer.state.tasks['one']?.items.single.text, 'Hello world');
    expect(reducer.state.eventRevision, 1);
  });

  test('replacing task items clears its expanded history window only', () {
    final epoch = reducer.beginConnection();
    final refresh = reducer.beginRefresh(epoch);
    reducer.applyRefresh(
      refresh,
      [snapshot('one', text: 'old history'), snapshot('two', text: 'sibling')],
      const {},
    );

    reducer.replaceItems(
      epoch,
      'one',
      const [
        TaskItem(id: 'recent', kind: TaskItemKind.agent, text: 'recent tail'),
      ],
    );

    expect(
      reducer.state.tasks['one']?.items.map((item) => item.text),
      ['recent tail'],
    );
    expect(reducer.state.tasks['two']?.items.single.text, 'sibling');
  });

  test('prepending older items preserves order while current items win', () {
    final epoch = reducer.beginConnection();
    final refresh = reducer.beginRefresh(epoch);
    reducer.applyRefresh(refresh, [snapshot('one')], const {});
    reducer.replaceItems(
      epoch,
      'one',
      const [
        TaskItem(id: 'overlap', kind: TaskItemKind.agent, text: 'live value'),
        TaskItem(id: 'recent', kind: TaskItemKind.user, text: 'recent'),
      ],
    );

    reducer.prependItems(
      epoch,
      'one',
      const [
        TaskItem(id: 'oldest', kind: TaskItemKind.user, text: 'oldest'),
        TaskItem(
          id: 'overlap',
          kind: TaskItemKind.agent,
          text: 'stale snapshot',
        ),
      ],
    );

    expect(
      reducer.state.tasks['one']?.items.map((item) => item.text),
      ['oldest', 'live value', 'recent'],
    );
  });

  test('a pending user message is visible before the server responds', () {
    final epoch = reducer.beginConnection();
    final refresh = reducer.beginRefresh(epoch);
    reducer.applyRefresh(refresh, [snapshot('one')], const {});

    reducer.appendPendingUserMessage(
      epoch,
      'one',
      'pending-1',
      'Please continue',
    );

    final item = reducer.state.tasks['one']!.items.single;
    expect(item.id, 'pending-1');
    expect(item.kind, TaskItemKind.user);
    expect(item.text, 'Please continue');
    expect(item.status, 'sending');
  });

  test('the server user item replaces the oldest matching pending message', () {
    final epoch = reducer.beginConnection();
    reducer.appendPendingUserMessage(epoch, 'one', 'pending-1', 'Continue');
    reducer.appendPendingUserMessage(epoch, 'one', 'pending-2', 'Continue');

    reducer.applyEvent(
      epoch,
      const TaskEvent.itemChanged(
        'one',
        TaskItem(
          id: 'server-user',
          kind: TaskItemKind.user,
          text: 'Continue',
        ),
      ),
    );

    expect(
      reducer.state.tasks['one']?.items.map((item) => item.id),
      ['server-user', 'pending-2'],
    );
  });

  test('RPC completion does not recreate a reconciled pending message', () {
    final epoch = reducer.beginConnection();
    reducer.appendPendingUserMessage(epoch, 'one', 'pending', 'Continue');
    reducer.applyEvent(
      epoch,
      const TaskEvent.itemChanged(
        'one',
        TaskItem(
          id: 'server-user',
          kind: TaskItemKind.user,
          text: 'Continue',
        ),
      ),
    );

    reducer.updatePendingUserMessageStatus(
      epoch,
      'one',
      'pending',
      'sent',
    );

    expect(
      reducer.state.tasks['one']?.items.map((item) => item.id),
      ['server-user'],
    );
  });

  test('an older server event cannot consume a queued message', () {
    final epoch = reducer.beginConnection();
    reducer.applyEvent(
      epoch,
      const TaskEvent.itemChanged(
        'one',
        TaskItem(
          id: 'queued',
          kind: TaskItemKind.user,
          text: 'Repeat',
          status: 'queued',
        ),
      ),
    );

    reducer.applyEvent(
      epoch,
      const TaskEvent.itemChanged(
        'one',
        TaskItem(id: 'older', kind: TaskItemKind.user, text: 'Repeat'),
      ),
    );

    expect(
      reducer.state.tasks['one']?.items.map((item) => item.id),
      ['queued', 'older'],
    );
  });

  test('latest page catch-up preserves older context and appends missed reply',
      () {
    final epoch = reducer.beginConnection();
    reducer.replaceItems(
      epoch,
      'one',
      const [
        TaskItem(id: 'old', kind: TaskItemKind.agent, text: 'Older context'),
        TaskItem(id: 'overlap', kind: TaskItemKind.agent, text: 'Before drop'),
        TaskItem(
          id: 'pending',
          kind: TaskItemKind.user,
          text: 'Keep going',
          status: 'sending',
        ),
      ],
    );

    reducer.mergeLatestItems(
      epoch,
      'one',
      const [
        TaskItem(
          id: 'overlap',
          kind: TaskItemKind.agent,
          text: 'Before drop',
        ),
        TaskItem(
          id: 'server-user',
          kind: TaskItemKind.user,
          text: 'Keep going',
        ),
        TaskItem(
          id: 'missed-reply',
          kind: TaskItemKind.agent,
          text: 'Recovered reply',
        ),
      ],
    );

    expect(
      reducer.state.tasks['one']?.items.map((item) => item.id),
      ['old', 'overlap', 'server-user', 'missed-reply'],
    );
  });
}
