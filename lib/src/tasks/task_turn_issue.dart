final class TaskTurnIssue {
  const TaskTurnIssue({
    required this.turnId,
    required this.message,
    this.code,
    this.details,
  });

  final String turnId;
  final String? message;
  final String? code;
  final String? details;

  TaskTurnIssue withDetailsFrom(TaskTurnIssue other) => TaskTurnIssue(
        turnId: turnId,
        message: message ?? other.message,
        code: code ?? other.code,
        details: details ?? other.details,
      );
}

/// Keeps the latest issue for each task without replaying old alerts on
/// reconnect or showing both notifications for the same failed turn.
final class TaskTurnIssues {
  static const _limit = 128;
  final _latest = <String, TaskTurnIssue>{};
  final _seen = <(String, String)>{};
  final _pending = <String, String>{};
  int revision = 0;

  TaskTurnIssue? forTask(String threadId) => _latest[threadId];

  bool hasPopup(String threadId, String turnId) => _pending[threadId] == turnId;

  bool takePopup(String threadId, String turnId) {
    if (!hasPopup(threadId, turnId)) return false;
    _pending.remove(threadId);
    return true;
  }

  void record(String threadId, TaskTurnIssue issue, {bool popup = false}) {
    final first = _seen.add((threadId, issue.turnId));
    final previous = _latest[threadId];
    if (!first && previous?.turnId != issue.turnId) return;
    if (_seen.length > _limit) _seen.remove(_seen.first);
    if (first) {
      _pending.remove(threadId);
      if (popup) _pending[threadId] = issue.turnId;
    }
    _store(
      threadId,
      previous?.turnId == issue.turnId ? issue.withDetailsFrom(previous!) : issue,
    );
  }

  void restore(String threadId, TaskTurnIssue issue) {
    final previous = _latest[threadId];
    if (previous?.turnId == issue.turnId) {
      _store(threadId, previous!.withDetailsFrom(issue));
    } else if (!_pending.containsKey(threadId)) {
      _store(threadId, issue);
    }
  }

  void _store(String threadId, TaskTurnIssue issue) {
    _latest.remove(threadId);
    _latest[threadId] = issue;
    if (_latest.length > _limit) {
      final oldest = _latest.keys.first;
      _latest.remove(oldest);
      _pending.remove(oldest);
    }
    revision++;
  }

  void turnStarted() => revision++;

  void clearTask(String threadId) {
    _latest.remove(threadId);
    _pending.remove(threadId);
    revision++;
  }

  void clear() {
    _latest.clear();
    _seen.clear();
    _pending.clear();
    revision++;
  }
}
