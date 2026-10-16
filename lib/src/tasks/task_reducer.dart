import 'message_attachments.dart';

enum TaskStatus { unknown, queued, running, completed, failed, interrupted }

enum TaskOwnership { available, local, external }

enum TaskItemKind { user, agent, command, file, tool, reasoning, notice }

final class TaskQuestion {
  const TaskQuestion({required this.title, this.options = const []});

  final String title;
  final List<String> options;
}

final class TaskItem {
  const TaskItem({
    required this.id,
    required this.kind,
    required this.text,
    this.title,
    this.detail,
    this.status,
    this.attachments = const [],
    this.questions = const [],
  });

  final String id;
  final TaskItemKind kind;
  final String text;
  final String? title;
  final String? detail;
  final String? status;
  final List<MessageAttachment> attachments;
  final List<TaskQuestion> questions;

  TaskItem copyWith({
    String? text,
    String? title,
    String? detail,
    String? status,
    List<TaskQuestion>? questions,
  }) =>
      TaskItem(
        id: id,
        kind: kind,
        text: text ?? this.text,
        title: title ?? this.title,
        detail: detail ?? this.detail,
        status: status ?? this.status,
        attachments: attachments,
        questions: questions ?? this.questions,
      );
}

final class TaskSnapshot {
  const TaskSnapshot({
    required this.id,
    required this.title,
    required this.status,
    required this.cwd,
    required this.updatedAt,
    required this.items,
    this.projectId,
    this.model,
    this.reasoningEffort,
  });

  final String id;
  final String title;
  final TaskStatus status;
  final String cwd;
  final DateTime updatedAt;
  final List<TaskItem> items;
  final String? projectId;
  final String? model;
  final String? reasoningEffort;
}

final class TaskRecord {
  const TaskRecord({
    required this.id,
    required this.title,
    required this.status,
    required this.cwd,
    required this.updatedAt,
    required this.items,
    required this.ownership,
    required this.revision,
    this.model,
    this.reasoningEffort,
  });

  factory TaskRecord.placeholder(String id, int revision) => TaskRecord(
        id: id,
        title: 'Task $id',
        status: TaskStatus.unknown,
        cwd: '',
        updatedAt: DateTime.now().toUtc(),
        items: const [],
        ownership: TaskOwnership.available,
        revision: revision,
      );

  final String id;
  final String title;
  final TaskStatus status;
  final String cwd;
  final DateTime updatedAt;
  final List<TaskItem> items;
  final TaskOwnership ownership;
  final int revision;
  final String? model;
  final String? reasoningEffort;

  TaskRecord copyWith({
    String? title,
    TaskStatus? status,
    String? cwd,
    DateTime? updatedAt,
    List<TaskItem>? items,
    TaskOwnership? ownership,
    int? revision,
    String? model,
    String? reasoningEffort,
    bool replaceTurnSettings = false,
  }) =>
      TaskRecord(
        id: id,
        title: title ?? this.title,
        status: status ?? this.status,
        cwd: cwd ?? this.cwd,
        updatedAt: updatedAt ?? this.updatedAt,
        items: items ?? this.items,
        ownership: ownership ?? this.ownership,
        revision: revision ?? this.revision,
        model: replaceTurnSettings ? model : model ?? this.model,
        reasoningEffort: replaceTurnSettings
            ? reasoningEffort
            : reasoningEffort ?? this.reasoningEffort,
      );
}

final class TaskState {
  const TaskState({
    required this.epoch,
    required this.refreshGeneration,
    required this.eventRevision,
    required this.tasks,
  });

  factory TaskState.initial() => const TaskState(
        epoch: 0,
        refreshGeneration: 0,
        eventRevision: 0,
        tasks: {},
      );

  final int epoch;
  final int refreshGeneration;
  final int eventRevision;
  final Map<String, TaskRecord> tasks;
}

final class RefreshToken {
  const RefreshToken(this.epoch, this.generation, this.eventRevision);

  final int epoch;
  final int generation;
  final int eventRevision;
}

final class PageMergeToken {
  const PageMergeToken(this.epoch, this.eventRevision);

  final int epoch;
  final int eventRevision;
}

enum _TaskEventType { status, agentDelta, item }

// Items are immutable: retaining this list is cheap even for long timelines.
final class TaskItemsReadToken {
  const TaskItemsReadToken(this.epoch, this.taskId, this.items);

  final int epoch;
  final String taskId;
  final List<TaskItem> items;
}

final class TaskEvent {
  const TaskEvent.statusChanged(this.taskId, this.status)
      : _type = _TaskEventType.status,
        itemId = null,
        eventId = null,
        delta = null,
        item = null;

  const TaskEvent.agentDelta(
    this.taskId,
    this.itemId,
    this.eventId,
    this.delta,
  )   : _type = _TaskEventType.agentDelta,
        item = null,
        status = null;

  const TaskEvent.itemChanged(this.taskId, this.item)
      : _type = _TaskEventType.item,
        itemId = null,
        eventId = null,
        delta = null,
        status = null;

  final String taskId;
  final _TaskEventType _type;
  final TaskStatus? status;
  final String? itemId;
  final String? eventId;
  final String? delta;
  final TaskItem? item;
}

final class TaskReducer {
  TaskState _state = TaskState.initial();
  final Map<String, Set<String>> _seenEvents = {};

  TaskState get state => _state;

  void setTurnSettings(
      int epoch, String taskId, String? model, String? effort) {
    if (epoch != _state.epoch) return;
    final current = _state.tasks[taskId];
    if (current == null || model == null) return;
    final revision = _state.eventRevision + 1;
    _state = TaskState(
      epoch: epoch,
      refreshGeneration: _state.refreshGeneration,
      eventRevision: revision,
      tasks: Map.unmodifiable({
        ..._state.tasks,
        taskId: current.copyWith(
            model: model,
            reasoningEffort: effort,
            replaceTurnSettings: true,
            revision: revision),
      }),
    );
  }

  void markLocalParticipation(int epoch, String taskId) {
    if (epoch != _state.epoch) return;
    final current = _state.tasks[taskId];
    if (current == null) return;
    final revision = _state.eventRevision + 1;
    _state = TaskState(
      epoch: epoch,
      refreshGeneration: _state.refreshGeneration,
      eventRevision: revision,
      tasks: Map.unmodifiable({
        ..._state.tasks,
        taskId: current.copyWith(
          ownership: TaskOwnership.local,
          revision: revision,
        ),
      }),
    );
  }

  int beginConnection({bool clearTasks = true}) {
    _seenEvents.clear();
    _state = TaskState(
      epoch: _state.epoch + 1,
      refreshGeneration: 0,
      eventRevision: _state.eventRevision,
      tasks: clearTasks ? const {} : _state.tasks,
    );
    return _state.epoch;
  }

  RefreshToken beginRefresh(int epoch) {
    if (epoch != _state.epoch) {
      return RefreshToken(epoch, -1, _state.eventRevision);
    }
    _state = TaskState(
      epoch: _state.epoch,
      refreshGeneration: _state.refreshGeneration + 1,
      eventRevision: _state.eventRevision,
      tasks: _state.tasks,
    );
    return RefreshToken(
      epoch,
      _state.refreshGeneration,
      _state.eventRevision,
    );
  }

  PageMergeToken capturePageMerge(int epoch) =>
      PageMergeToken(epoch, _state.eventRevision);

  bool applyRefresh(
    RefreshToken token,
    List<TaskSnapshot> snapshots,
    Set<String> loadedByUs, {
    bool retainExisting = false,
  }) {
    if (token.epoch != _state.epoch ||
        token.generation != _state.refreshGeneration) {
      return false;
    }

    _applySnapshots(
      eventRevision: token.eventRevision,
      snapshots: snapshots,
      loadedByUs: loadedByUs,
      retainExisting: retainExisting,
    );
    return true;
  }

  bool applyPageMerge(
    PageMergeToken token,
    List<TaskSnapshot> snapshots,
    Set<String> loadedByUs,
  ) {
    if (token.epoch != _state.epoch) return false;
    _applySnapshots(
      eventRevision: token.eventRevision,
      snapshots: snapshots,
      loadedByUs: loadedByUs,
      retainExisting: true,
    );
    return true;
  }

  void _applySnapshots({
    required int eventRevision,
    required List<TaskSnapshot> snapshots,
    required Set<String> loadedByUs,
    required bool retainExisting,
  }) {
    final next = retainExisting
        ? Map<String, TaskRecord>.of(_state.tasks)
        : <String, TaskRecord>{};
    for (final snapshot in snapshots) {
      final current = _state.tasks[snapshot.id];
      final changedDuringRefresh =
          current != null && current.revision > eventRevision;
      final effectiveStatus =
          changedDuringRefresh ? current.status : snapshot.status;
      final preserveItems = changedDuringRefresh ||
          (snapshot.items.isEmpty && (current?.items.isNotEmpty ?? false));
      final ownership = _ownershipFor(effectiveStatus, loadedByUs, snapshot.id);
      next[snapshot.id] = TaskRecord(
        id: snapshot.id,
        title: snapshot.title,
        status: effectiveStatus,
        cwd: snapshot.cwd,
        updatedAt:
            changedDuringRefresh ? current.updatedAt : snapshot.updatedAt,
        items: preserveItems ? current!.items : snapshot.items,
        ownership: ownership,
        revision: current?.revision ?? eventRevision,
        model: changedDuringRefresh
            ? current.model
            : snapshot.model ?? current?.model,
        reasoningEffort: changedDuringRefresh
            ? current.reasoningEffort
            : snapshot.model != null
                ? snapshot.reasoningEffort
                : current?.reasoningEffort,
      );
    }

    for (final entry in _state.tasks.entries) {
      if (!next.containsKey(entry.key) &&
          entry.value.revision > eventRevision) {
        next[entry.key] = entry.value;
      }
    }
    _state = TaskState(
      epoch: _state.epoch,
      refreshGeneration: _state.refreshGeneration,
      eventRevision: _state.eventRevision,
      tasks: Map.unmodifiable(next),
    );
  }

  void applySnapshot(
    int epoch,
    TaskSnapshot snapshot,
    Set<String> loadedByUs,
  ) {
    if (epoch != _state.epoch) return;
    final current = _state.tasks[snapshot.id];
    final status = current?.status ?? snapshot.status;
    final tasks = Map<String, TaskRecord>.of(_state.tasks)
      ..[snapshot.id] = TaskRecord(
        id: snapshot.id,
        title: snapshot.title,
        status: status,
        cwd: snapshot.cwd,
        updatedAt:
            current != null && current.updatedAt.isAfter(snapshot.updatedAt)
                ? current.updatedAt
                : snapshot.updatedAt,
        items: _mergeItems(snapshot.items, current?.items ?? const []),
        ownership: _ownershipFor(status, loadedByUs, snapshot.id),
        revision: current?.revision ?? _state.eventRevision,
        model: snapshot.model ?? current?.model,
        reasoningEffort: snapshot.model != null
            ? snapshot.reasoningEffort
            : current?.reasoningEffort,
      );
    _state = TaskState(
      epoch: _state.epoch,
      refreshGeneration: _state.refreshGeneration,
      eventRevision: _state.eventRevision,
      tasks: Map.unmodifiable(tasks),
    );
  }

  void replaceItems(int epoch, String taskId, List<TaskItem> items) {
    if (epoch != _state.epoch) return;
    final current = _state.tasks[taskId] ??
        TaskRecord.placeholder(taskId, _state.eventRevision);
    _replaceTaskItems(current, items);
  }

  void prependItems(int epoch, String taskId, List<TaskItem> olderItems) {
    if (epoch != _state.epoch) return;
    final current = _state.tasks[taskId] ??
        TaskRecord.placeholder(taskId, _state.eventRevision);
    final currentById = {
      for (final item in current.items) item.id: item,
    };
    final seen = <String>{};
    final resolved = <TaskItem>[];
    for (final item in olderItems) {
      if (!seen.add(item.id)) continue;
      resolved.add(currentById[item.id] ?? item);
    }
    _replaceTaskItems(
        current,
        _mergeOrderedPage(current.items, resolved,
            prependWithoutOverlap: true));
  }

  TaskItemsReadToken captureItemsRead(int epoch, String taskId) =>
      TaskItemsReadToken(
          epoch, taskId, _state.tasks[taskId]?.items ?? const []);

  void appendPendingUserMessage(
    int epoch,
    String taskId,
    String itemId,
    String text,
  ) {
    applyEvent(
      epoch,
      TaskEvent.itemChanged(
        taskId,
        TaskItem(
          id: itemId,
          kind: TaskItemKind.user,
          text: text,
          status: 'sending',
        ),
      ),
    );
  }

  void updatePendingUserMessageStatus(
    int epoch,
    String taskId,
    String itemId,
    String status,
  ) {
    if (epoch != _state.epoch) return;
    final current = _state.tasks[taskId];
    if (current == null) return;
    final index = current.items.indexWhere((item) => item.id == itemId);
    if (index == -1) return;
    final item = current.items[index];
    if (!_isPendingUserItem(item)) return;
    applyEvent(
      epoch,
      TaskEvent.itemChanged(taskId, item.copyWith(status: status)),
    );
  }

  void mergeLatestItems(
    int epoch,
    String taskId,
    List<TaskItem> latestItems, {
    TaskItemsReadToken? readToken,
  }) {
    if (epoch != _state.epoch || latestItems.isEmpty) return;
    if (readToken != null &&
        (readToken.epoch != epoch || readToken.taskId != taskId)) {
      return;
    }
    final current = _state.tasks[taskId] ??
        TaskRecord.placeholder(taskId, _state.eventRevision);
    final currentItems = current.items;
    if (currentItems.isEmpty) {
      _replaceTaskItems(current, latestItems);
      return;
    }

    final claimedPendingIndices = <int>{};
    final pendingReplacements = <int, TaskItem>{};
    final beforeRead = readToken == null
        ? null
        : {for (final item in readToken.items) item.id: item};
    final resolvedLatest = <TaskItem>[];
    final seenLatestIds = <String>{};
    for (final latest in latestItems) {
      if (!seenLatestIds.add(latest.id)) continue;
      var currentIndex = currentItems.indexWhere(
        (item) => item.id == latest.id,
      );
      if (currentIndex == -1 && latest.kind == TaskItemKind.user) {
        currentIndex = _matchingPendingUserIndex(
          currentItems,
          latest.text,
          claimedPendingIndices,
        );
        if (currentIndex != -1) {
          claimedPendingIndices.add(currentIndex);
          pendingReplacements[currentIndex] = latest;
        }
      }
      final existing = currentIndex == -1 ? null : currentItems[currentIndex];
      resolvedLatest.add(
        existing == null ||
                (beforeRead != null &&
                    identical(beforeRead[latest.id], existing))
            ? latest
            : beforeRead == null || existing.id != latest.id
                ? _preferCurrentStreamingItem(existing, latest)
                : _preferItemChangedDuringRead(existing, latest),
      );
    }

    // Replace optimistic IDs before finding anchors, keeping their position.
    final anchoredCurrent = [
      for (var index = 0; index < currentItems.length; index++)
        pendingReplacements[index] ?? currentItems[index],
    ];
    _replaceTaskItems(
        current, _mergeOrderedPage(anchoredCurrent, resolvedLatest));
  }

  void _replaceTaskItems(TaskRecord current, List<TaskItem> items) {
    final tasks = Map<String, TaskRecord>.of(_state.tasks)
      ..[current.id] = current.copyWith(items: List.unmodifiable(items));
    _state = TaskState(
      epoch: _state.epoch,
      refreshGeneration: _state.refreshGeneration,
      eventRevision: _state.eventRevision,
      tasks: Map.unmodifiable(tasks),
    );
  }

  void applyEvent(int epoch, TaskEvent event) {
    applyEvents(epoch, [event]);
  }

  void applyEvents(int epoch, List<TaskEvent> events) {
    if (epoch != _state.epoch) return;
    final coalesced = <TaskEvent>[];
    for (final event in events) {
      if (event._type == _TaskEventType.agentDelta) {
        final eventId = event.eventId;
        if (eventId != null) {
          final seen = _seenEvents.putIfAbsent(event.taskId, () => <String>{});
          if (!seen.add(eventId)) continue;
        }
        final previous = coalesced.isEmpty ? null : coalesced.last;
        if (previous?._type == _TaskEventType.agentDelta &&
            previous?.taskId == event.taskId &&
            previous?.itemId == event.itemId) {
          coalesced[coalesced.length - 1] = TaskEvent.agentDelta(
            event.taskId,
            event.itemId,
            null,
            '${previous!.delta}${event.delta}',
          );
          continue;
        }
      }
      coalesced.add(event);
    }
    if (coalesced.isEmpty) return;

    final revision = _state.eventRevision + 1;
    final tasks = Map<String, TaskRecord>.of(_state.tasks);
    for (final event in coalesced) {
      var current =
          tasks[event.taskId] ?? TaskRecord.placeholder(event.taskId, revision);

      switch (event._type) {
        case _TaskEventType.status:
          final active = event.status == TaskStatus.running ||
              event.status == TaskStatus.queued;
          current = current.copyWith(
            status: event.status,
            ownership: active ? current.ownership : TaskOwnership.available,
            updatedAt: DateTime.now().toUtc(),
            revision: revision,
          );
          break;
        case _TaskEventType.agentDelta:
          final items = current.items.toList();
          final index = items.indexWhere((item) => item.id == event.itemId);
          if (index == -1) {
            items.add(TaskItem(
              id: event.itemId!,
              kind: TaskItemKind.agent,
              text: event.delta!,
            ));
          } else {
            items[index] = items[index].copyWith(
              text: '${items[index].text}${event.delta}',
            );
          }
          current = current.copyWith(
            items: List.unmodifiable(items),
            revision: revision,
          );
          break;
        case _TaskEventType.item:
          final items = current.items.toList();
          final changedItem = event.item!;
          var index = items.indexWhere((item) => item.id == changedItem.id);
          if (index == -1 &&
              changedItem.kind == TaskItemKind.user &&
              !_isPendingUserItem(changedItem)) {
            index = _matchingPendingUserIndex(
              items,
              changedItem.text,
              const <int>{},
            );
          }
          if (index == -1) {
            items.add(changedItem);
          } else {
            items[index] = changedItem;
          }
          current = current.copyWith(
            items: List.unmodifiable(items),
            revision: revision,
          );
          break;
      }
      tasks[event.taskId] = current;
    }

    _state = TaskState(
      epoch: _state.epoch,
      refreshGeneration: _state.refreshGeneration,
      eventRevision: revision,
      tasks: Map.unmodifiable(tasks),
    );
  }
}

int _matchingPendingUserIndex(
  List<TaskItem> items,
  String text,
  Set<int> excludedIndices,
) {
  final normalizedText = _normalizedUserMessageText(text);
  for (var index = 0; index < items.length; index++) {
    final item = items[index];
    if (!excludedIndices.contains(index) &&
        _isPendingUserItem(item) &&
        _normalizedUserMessageText(item.text) == normalizedText) {
      return index;
    }
  }
  return -1;
}

String _normalizedUserMessageText(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();

bool _isPendingUserItem(TaskItem item) =>
    item.kind == TaskItemKind.user &&
    (item.status == 'sending' || item.status == 'sent');

TaskItem _preferCurrentStreamingItem(TaskItem current, TaskItem latest) {
  if (current.kind == TaskItemKind.agent &&
      latest.kind == TaskItemKind.agent &&
      current.text.length > latest.text.length &&
      current.text.startsWith(latest.text)) {
    return current.copyWith(
      questions: latest.questions.isEmpty ? null : latest.questions,
    );
  }
  return latest;
}

TaskItem _preferItemChangedDuringRead(TaskItem current, TaskItem latest) {
  // A growing snapshot may include more of the same stream. Otherwise retain
  // the event received while the request was in flight (including completion).
  if (current.kind == TaskItemKind.agent &&
      latest.kind == TaskItemKind.agent &&
      current.status != 'completed' &&
      latest.text.length > current.text.length &&
      latest.text.startsWith(current.text)) {
    return latest;
  }
  return current;
}

List<TaskItem> _mergeOrderedPage(
  List<TaskItem> current,
  List<TaskItem> page, {
  bool prependWithoutOverlap = false,
}) {
  final positions = {for (var i = 0; i < current.length; i++) current[i].id: i};
  final pageIds = page.map((item) => item.id).toSet();
  final overlaps = page.map((item) => positions[item.id]).whereType<int>();
  if (overlaps.isEmpty) {
    return prependWithoutOverlap
        ? [...page, ...current]
        : [...current, ...page];
  }
  var cursor = overlaps.reduce((a, b) => a < b ? a : b);
  final result = current.take(cursor).toList();
  for (final item in page) {
    final position = positions[item.id];
    if (position != null && position >= cursor) {
      for (var i = cursor; i < position; i++) {
        if (!pageIds.contains(current[i].id)) result.add(current[i]);
      }
      cursor = position + 1;
    }
    result.add(item);
  }
  result
      .addAll(current.skip(cursor).where((item) => !pageIds.contains(item.id)));
  return result;
}

List<TaskItem> _mergeItems(
  List<TaskItem> snapshot,
  List<TaskItem> current,
) {
  final items = <String, TaskItem>{
    for (final item in snapshot) item.id: item,
    for (final item in current) item.id: item,
  };
  return List.unmodifiable(items.values);
}

TaskOwnership _ownershipFor(
  TaskStatus status,
  Set<String> loadedByUs,
  String taskId,
) {
  final active = status == TaskStatus.running || status == TaskStatus.queued;
  if (!active) return TaskOwnership.available;
  return loadedByUs.contains(taskId)
      ? TaskOwnership.local
      : TaskOwnership.external;
}
