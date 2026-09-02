import 'package:flutter/material.dart';

import '../../tasks/task_reducer.dart';
import 'codex_directive_content.dart';
import 'markdown_content.dart';

class TimelineItemView extends StatelessWidget {
  const TimelineItemView({required this.item, super.key});

  final TaskItem item;

  @override
  Widget build(BuildContext context) {
    return switch (item.kind) {
      TaskItemKind.user || TaskItemKind.agent => _Message(item: item),
      _ => _ActivityCard(item: item),
    };
  }
}

class TimelineActivityGroup extends StatelessWidget {
  const TimelineActivityGroup({required this.items, super.key});

  final List<TaskItem> items;

  @override
  Widget build(BuildContext context) {
    final count = items.length;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Card(
        key: const Key('activity-group'),
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          dense: true,
          visualDensity: const VisualDensity(vertical: -3),
          leading: const Icon(Icons.build_circle_outlined, size: 19),
          title: Text('$count work ${count == 1 ? 'event' : 'events'}'),
          subtitle: Text(
            items.map((item) => item.title ?? _activityLabel(item)).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          children: [
            for (final item in items) _CompactActivityRow(item: item),
          ],
        ),
      ),
    );
  }
}

class _CompactActivityRow extends StatelessWidget {
  const _CompactActivityRow({required this.item});

  final TaskItem item;

  @override
  Widget build(BuildContext context) {
    final detail = item.detail?.trim();
    final subtitle = item.text.trim();
    return ExpansionTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -4),
      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
      childrenPadding: const EdgeInsets.fromLTRB(38, 0, 8, 8),
      leading: Icon(
        _activityIcon(item),
        size: 17,
        color: _activityColor(context, item),
      ),
      title: Text(
        item.title ?? _activityLabel(item),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: item.status == null ? null : _StatusBadge(status: item.status!),
      showTrailingIcon: detail?.isNotEmpty == true,
      children: detail?.isNotEmpty == true
          ? [
              Align(
                alignment: Alignment.centerLeft,
                child: item.kind == TaskItemKind.reasoning
                    ? MarkdownContent(text: detail!)
                    : SelectableText(
                        detail!,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
              ),
            ]
          : const [],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.item});

  final TaskItem item;

  @override
  Widget build(BuildContext context) {
    final user = item.kind == TaskItemKind.user;
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 720),
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: user ? colors.primaryContainer : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment:
              user ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (user)
              MarkdownContent(text: item.text)
            else
              CodexDirectiveContent(text: item.text),
            if (user && item.status == 'sending') ...[
              const SizedBox(height: 6),
              const SizedBox(
                key: Key('pending-user-progress'),
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.item});

  final TaskItem item;

  @override
  Widget build(BuildContext context) {
    final expandable = item.kind == TaskItemKind.reasoning ||
        item.detail?.trim().isNotEmpty == true;
    final detail = item.detail?.trim();
    final body =
        item.kind == TaskItemKind.reasoning && detail?.isNotEmpty == true
            ? '${item.text.trim()}\n\n$detail'
            : detail?.isNotEmpty == true
                ? detail!
                : item.text.trim();
    final tile = ExpansionTile(
      leading: Icon(
        _activityIcon(item),
        size: 20,
        color: _activityColor(context, item),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              item.title ?? _activityLabel(item),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (item.status != null) _StatusBadge(status: item.status!),
        ],
      ),
      subtitle: item.kind == TaskItemKind.reasoning || item.text == body
          ? null
          : Text(item.text, maxLines: 2, overflow: TextOverflow.ellipsis),
      initiallyExpanded: !expandable,
      showTrailingIcon: expandable,
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: item.kind == TaskItemKind.reasoning
              ? MarkdownContent(text: body)
              : SelectableText(
                  body,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: tile,
      ),
    );
  }
}

IconData _activityIcon(TaskItem item) => switch (item.kind) {
      TaskItemKind.command => Icons.terminal,
      TaskItemKind.file => Icons.difference_outlined,
      TaskItemKind.tool => Icons.build_outlined,
      TaskItemKind.reasoning => Icons.psychology_outlined,
      _ => Icons.info_outline,
    };

String _activityLabel(TaskItem item) => switch (item.kind) {
      TaskItemKind.command => 'Command',
      TaskItemKind.file => 'File changes',
      TaskItemKind.tool => 'Tool',
      TaskItemKind.reasoning => 'Reasoning',
      _ => 'Activity',
    };

Color _activityColor(BuildContext context, TaskItem item) =>
    switch (item.kind) {
      TaskItemKind.command => Theme.of(context).colorScheme.secondary,
      TaskItemKind.file => Theme.of(context).colorScheme.primary,
      TaskItemKind.tool => Theme.of(context).colorScheme.tertiary,
      _ => Theme.of(context).colorScheme.outline,
    };

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(status, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}
