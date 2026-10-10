import 'task_reducer.dart';

enum TaskMessageRoute { start, steer, queue }

enum TaskSendMode { auto, steer, queue }

TaskMessageRoute chooseExplicitMessageRoute(TaskSendMode mode,
    {required String? activeTurnId}) {
  if (mode == TaskSendMode.queue) return TaskMessageRoute.queue;
  if (mode == TaskSendMode.steer && activeTurnId != null) {
    return TaskMessageRoute.steer;
  }
  throw StateError('No active turn to steer. Use Auto to start a new turn.');
}

enum TaskMessageDisposition { started, steered, queued }

enum QueuedPromptAction { start, wait }

TaskMessageRoute chooseTaskMessageRoute(
  TaskStatus status, {
  required String? activeTurnId,
}) {
  if (activeTurnId != null) return TaskMessageRoute.steer;
  if (status == TaskStatus.running || status == TaskStatus.queued) {
    return TaskMessageRoute.queue;
  }
  return TaskMessageRoute.start;
}

QueuedPromptAction chooseQueuedPromptAction(
  TaskStatus status, {
  required String? activeTurnId,
  required bool activeTurnChecked,
}) {
  if (activeTurnId != null) return QueuedPromptAction.wait;
  final cachedActive =
      status == TaskStatus.running || status == TaskStatus.queued;
  return cachedActive && !activeTurnChecked
      ? QueuedPromptAction.wait
      : QueuedPromptAction.start;
}

final class TaskMessageQueue<T> {
  final Map<String, List<T>> _messages = {};

  Set<String> get threadIds => Set.unmodifiable(_messages.keys);

  bool hasPending(String threadId) => _messages[threadId]?.isNotEmpty == true;

  List<T> values(String threadId) =>
      List<T>.unmodifiable(_messages[threadId] ?? const []);

  void enqueue(String threadId, T message) {
    _messages.putIfAbsent(threadId, () => <T>[]).add(message);
  }

  T? peek(String threadId) {
    final pending = _messages[threadId];
    return pending == null || pending.isEmpty ? null : pending.first;
  }

  T? take(String threadId) {
    final pending = _messages[threadId];
    if (pending == null || pending.isEmpty) return null;
    final message = pending.removeAt(0);
    if (pending.isEmpty) _messages.remove(threadId);
    return message;
  }

  bool remove(String threadId, T message) {
    final pending = _messages[threadId];
    if (pending == null || !pending.remove(message)) return false;
    if (pending.isEmpty) _messages.remove(threadId);
    return true;
  }

  void clear() => _messages.clear();
}
