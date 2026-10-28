import '../tasks/task_reducer.dart';

sealed class TimelineEntry {
  const TimelineEntry();
}

final class TimelineMessageEntry extends TimelineEntry {
  const TimelineMessageEntry(this.item);

  final TaskItem item;
}

final class TimelineActivityEntry extends TimelineEntry {
  const TimelineActivityEntry(this.items);

  final List<TaskItem> items;
}

List<TimelineEntry> buildTimelineEntries(List<TaskItem> items) {
  final entries = <TimelineEntry>[];
  var activities = <TaskItem>[];

  void flushActivities() {
    if (activities.isEmpty) return;
    entries.add(TimelineActivityEntry(List.unmodifiable(activities)));
    activities = <TaskItem>[];
  }

  for (final item in items) {
    final message =
        item.kind == TaskItemKind.user || item.kind == TaskItemKind.agent;
    if (!message) {
      activities.add(item);
      continue;
    }
    flushActivities();
    if (item.text.trim().isNotEmpty ||
        item.attachments.isNotEmpty ||
        item.questions.isNotEmpty) {
      entries.add(TimelineMessageEntry(item));
    }
  }
  flushActivities();
  return List.unmodifiable(entries);
}
