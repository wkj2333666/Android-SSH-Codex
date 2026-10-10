import 'package:android_ssh_codex/src/tasks/task_message_queue.dart';
import 'package:android_ssh_codex/src/tasks/task_operation_lock.dart';
import 'package:android_ssh_codex/src/tasks/task_reducer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('explicit steer requires a live turn; queue never becomes steer', () {
    expect(
        chooseExplicitMessageRoute(TaskSendMode.steer, activeTurnId: 'active'),
        TaskMessageRoute.steer);
    expect(
        () =>
            chooseExplicitMessageRoute(TaskSendMode.steer, activeTurnId: null),
        throwsStateError);
    expect(
        chooseExplicitMessageRoute(TaskSendMode.queue, activeTurnId: 'active'),
        TaskMessageRoute.queue);
    expect(chooseExplicitMessageRoute(TaskSendMode.queue, activeTurnId: null),
        TaskMessageRoute.queue);
  });
  test('pending messages remain FIFO and isolated per task', () {
    final queue = TaskMessageQueue<String>();

    queue.enqueue('one', 'first');
    queue.enqueue('one', 'second');
    queue.enqueue('two', 'other');

    expect(queue.take('one'), 'first');
    expect(queue.peek('one'), 'second');
    expect(queue.take('two'), 'other');
    expect(queue.take('one'), 'second');
    expect(queue.take('one'), isNull);
  });

  test('clearing the queue removes pending messages for every task', () {
    final queue = TaskMessageQueue<String>();
    queue.enqueue('one', 'first');
    queue.enqueue('two', 'second');

    queue.clear();

    expect(queue.threadIds, isEmpty);
    expect(queue.peek('one'), isNull);
    expect(queue.peek('two'), isNull);
  });

  test('a stale operation cannot release a replacement thread lock', () {
    final lock = TaskOperationLock();
    final staleOwner = lock.tryAcquire('one')!;

    lock.clear();
    final replacementOwner = lock.tryAcquire('one')!;
    lock.release('one', staleOwner);

    expect(lock.tryAcquire('one'), isNull);
    lock.release('one', replacementOwner);
    expect(lock.tryAcquire('one'), isNotNull);
  });

  test('queued messages expose an immutable FIFO snapshot and can be removed',
      () {
    final queue = TaskMessageQueue<String>();
    queue.enqueue('one', 'first');
    queue.enqueue('one', 'second');

    final snapshot = queue.values('one');

    expect(snapshot, ['first', 'second']);
    expect(() => snapshot.add('third'), throwsUnsupportedError);
    expect(queue.remove('one', 'second'), isTrue);
    expect(queue.values('one'), ['first']);
    expect(queue.remove('one', 'missing'), isFalse);
  });

  test('message routing steers active turns and queues an unresolved one', () {
    expect(
      chooseTaskMessageRoute(TaskStatus.running, activeTurnId: 'turn-1'),
      TaskMessageRoute.steer,
    );
    expect(
      chooseTaskMessageRoute(TaskStatus.running, activeTurnId: null),
      TaskMessageRoute.queue,
    );
    expect(
      chooseTaskMessageRoute(TaskStatus.completed, activeTurnId: null),
      TaskMessageRoute.start,
    );
  });

  test('a confirmed idle remote turn can flush stale running state', () {
    expect(
      chooseQueuedPromptAction(
        TaskStatus.running,
        activeTurnId: null,
        activeTurnChecked: true,
      ),
      QueuedPromptAction.start,
    );
    expect(
      chooseQueuedPromptAction(
        TaskStatus.running,
        activeTurnId: null,
        activeTurnChecked: false,
      ),
      QueuedPromptAction.wait,
    );
    expect(
      chooseQueuedPromptAction(
        TaskStatus.completed,
        activeTurnId: null,
        activeTurnChecked: false,
      ),
      QueuedPromptAction.start,
    );
  });
}
