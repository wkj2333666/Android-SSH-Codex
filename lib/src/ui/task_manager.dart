import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../tasks/task_reducer.dart';

/// Full server search and archive/pin management live behind one entry point.
class TaskManager extends StatefulWidget {
  const TaskManager({required this.controller, super.key});
  final AppController controller;

  @override
  State<TaskManager> createState() => _TaskManagerState();
}

class _TaskManagerState extends State<TaskManager> {
  final _search = TextEditingController();
  Timer? _debounce;
  List<TaskSnapshot> _tasks = [];
  String? _cursor;
  String? _error;
  bool _archived = false;
  bool _pinned = false;
  bool _loading = false;
  bool _mutating = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final generation = ++_generation;
    final host = widget.controller.selectedHostId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.controller.findTasks(
          query: _search.text,
          archived: _archived,
          pinned: _pinned ? true : null,
          cursor: more ? _cursor : null);
      if (!mounted ||
          generation != _generation ||
          host != widget.controller.selectedHostId) {
        return;
      }
      setState(() {
        _tasks = more ? [..._tasks, ...page.tasks] : page.tasks;
        _cursor = page.nextCursor;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _action(TaskSnapshot task, String action) async {
    if (_mutating) return;
    setState(() => _mutating = true);
    try {
      switch (action) {
        case 'rename':
          final name = await askTaskName(context, task.title);
          if (name == null || !mounted) return;
          await widget.controller.renameTask(task.id, name);
        case 'pin':
          await widget.controller.pinTask(task.id, !task.isPinned);
        case 'archive':
          if (!_archived && !await confirmArchive(context)) return;
          await widget.controller.archiveTask(task.id, !_archived);
      }
      if (mounted) await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
        child: SizedBox(
            width: 560,
            height: 620,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                Row(children: [
                  const Expanded(child: Text('Manage tasks')),
                  IconButton(
                      onPressed: () => Navigator.pop(context),
                      tooltip: 'Close',
                      icon: const Icon(Icons.close)),
                ]),
                TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                        hintText: 'Search all tasks',
                        prefixIcon: Icon(Icons.search)),
                    onChanged: (_) {
                      _debounce?.cancel();
                      ++_generation;
                      _debounce =
                          Timer(const Duration(milliseconds: 350), _load);
                    }),
                Wrap(spacing: 8, children: [
                  FilterChip(
                      label: const Text('Pinned'),
                      selected: _pinned,
                      onSelected: _mutating
                          ? null
                          : (v) {
                              setState(() => _pinned = v);
                              _load();
                            }),
                  FilterChip(
                      label: const Text('Archived'),
                      selected: _archived,
                      onSelected: _mutating
                          ? null
                          : (v) {
                              setState(() => _archived = v);
                              _load();
                            }),
                ]),
                if (_loading || _mutating) const LinearProgressIndicator(),
                if (_error != null) Text(_error!),
                Expanded(
                    child: ListView(children: [
                  for (final task in _tasks)
                    ListTile(
                      title: Text(task.title,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(task.cwd,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      leading: task.isPinned
                          ? const Icon(Icons.push_pin_outlined)
                          : null,
                      onTap: _archived || _mutating
                          ? null
                          : () {
                              Navigator.pop(context);
                              unawaited(widget.controller.openFoundTask(task));
                            },
                      trailing: PopupMenuButton<String>(
                          enabled: !_mutating && !_loading,
                          onSelected: (value) => _action(task, value),
                          itemBuilder: (_) => [
                                const PopupMenuItem(
                                    value: 'rename', child: Text('Rename')),
                                PopupMenuItem(
                                    value: 'pin',
                                    child:
                                        Text(task.isPinned ? 'Unpin' : 'Pin')),
                                PopupMenuItem(
                                    value: 'archive',
                                    child: Text(
                                        _archived ? 'Restore' : 'Archive')),
                              ]),
                    ),
                  if (!_loading && _tasks.isEmpty)
                    const ListTile(title: Text('No tasks found')),
                  if (_cursor != null)
                    TextButton(
                        onPressed: _loading ? null : () => _load(more: true),
                        child: const Text('Load more')),
                ])),
              ]),
            )),
      );
}

Future<String?> askTaskName(BuildContext context, String initial) async {
  final editor = TextEditingController(text: initial);
  final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
            title: const Text('Rename task'),
            content:
                TextField(controller: editor, autofocus: true, maxLength: 200),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () {
                    if (editor.text.trim().isNotEmpty) {
                      Navigator.pop(context, editor.text.trim());
                    }
                  },
                  child: const Text('Save')),
            ],
          ));
  // The dialog may still be animating out when its future completes.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  editor.dispose();
  return result;
}

Future<bool> confirmArchive(BuildContext context) async =>
    await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Archive task?'),
              content: const Text(
                  'This hides the task and may archive its child tasks. '
                  'You can restore it from Manage tasks → Archived.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Archive')),
              ],
            )) ??
    false;
