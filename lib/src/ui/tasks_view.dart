import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../projects/remote_project.dart';
import '../tasks/task_reducer.dart';
import 'task_view.dart';
import 'turn_settings_picker.dart';
import 'widgets/connection_badge.dart';

class TasksWorkspace extends StatelessWidget {
  const TasksWorkspace({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 800;
    final selected = controller.selectedTask;
    if (!wide && selected != null) {
      return SafeArea(
        child: TaskView(
          key: ValueKey(selected.id),
          controller: controller,
          task: selected,
        ),
      );
    }
    final list = _TaskList(controller: controller);
    if (!wide) return SafeArea(child: list);
    return SafeArea(
      child: Row(
        children: [
          SizedBox(width: 360, child: list),
          const VerticalDivider(width: 1),
          Expanded(
            child: selected == null
                ? const _NoTaskSelected()
                : TaskView(
                    key: ValueKey(selected.id),
                    controller: controller,
                    task: selected,
                  ),
          ),
        ],
      ),
    );
  }
}

class _TaskList extends StatelessWidget {
  const _TaskList({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return TaskListPane(
      model: TaskListPaneModel(
        projects: controller.projects,
        selectedProjectId: controller.selectedProjectId,
        selectedTaskId: controller.selectedTaskId,
        projectTasks: controller.projectTasks,
        recentTasks: controller.recentTasks,
        unassignedTasks: controller.unassignedTasks,
        connected: controller.isConnected,
        connectionPhase: controller.connectionPhase,
        unassignedExpanded: controller.unassignedExpanded,
        hasMoreProjectTasks: controller.hasMoreProjectTasks,
        hasMoreRecentTasks: controller.hasMoreRecentTasks,
        hasMoreUnassignedTasks: controller.hasMoreUnassignedTasks,
        loadingProjectPage: controller.isLoadingProjectPage,
        loadingRecentTasks: controller.isLoadingRecentTasks,
        loadingUnassignedPage: controller.isLoadingUnassignedPage,
      ),
      onRefresh: controller.refreshTasks,
      onAddProject: () => _editProject(context),
      onEditProject: () => _editProject(context, controller.selectedProject),
      onDeleteProject: () => _deleteProject(context),
      onProjectSelected: controller.selectProject,
      onNewTask: (mode) => _newTask(context, mode),
      onTaskSelected: controller.selectTask,
      onToggleUnassigned: controller.toggleUnassigned,
      onLoadMoreProjectTasks: controller.loadMoreProjectTasks,
      onLoadMoreRecentTasks: controller.loadMoreRecentTasks,
      onLoadMoreUnassignedTasks: controller.loadMoreUnassignedTasks,
    );
  }

  Future<void> _newTask(BuildContext context, TaskListMode mode) async {
    final project = mode == TaskListMode.projects
        ? controller.selectedProject
        : null;
    final cwd = TextEditingController(text: project?.cwd);
    final prompt = TextEditingController();
    var turnSettings = const TurnSettings();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New task'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (project == null)
                TextField(
                  controller: cwd,
                  decoration: const InputDecoration(
                    labelText: 'Remote working directory',
                    prefixIcon: Icon(Icons.folder_outlined),
                  ),
                )
              else
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(project.name),
                  subtitle: Text(project.cwd),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: prompt,
                minLines: 3,
                maxLines: 6,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Task',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 12),
              StatefulBuilder(
                builder: (context, setDialogState) => TurnSettingsPicker(
                  models: controller.models,
                  value: turnSettings,
                  onChanged: (value) =>
                      setDialogState(() => turnSettings = value),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Start'),
          ),
        ],
      ),
    );
    if (accepted == true &&
        cwd.text.trim().isNotEmpty &&
        prompt.text.trim().isNotEmpty) {
      await controller.startNewTask(
        cwd: cwd.text.trim(),
        prompt: prompt.text.trim(),
        model: turnSettings.model,
        effort: turnSettings.effort,
      );
    }
    cwd.dispose();
    prompt.dispose();
  }

  Future<void> _editProject(
    BuildContext context, [
    RemoteProject? project,
  ]) async {
    final name = TextEditingController(text: project?.name);
    final cwd = TextEditingController(text: project?.cwd);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(project == null ? 'Add project' : 'Edit project'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Project name',
                  prefixIcon: Icon(Icons.folder_copy_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: cwd,
                decoration: const InputDecoration(
                  labelText: 'Remote working directory',
                  prefixIcon: Icon(Icons.folder_outlined),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (accepted == true &&
        name.text.trim().isNotEmpty &&
        cwd.text.trim().isNotEmpty) {
      await controller.saveProject(
        projectId: project?.id,
        name: name.text,
        cwd: cwd.text,
      );
    }
    name.dispose();
    cwd.dispose();
  }

  Future<void> _deleteProject(BuildContext context) async {
    final project = controller.selectedProject;
    if (project == null) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete project?'),
        content: Text(
          'Remove ${project.name} from this app? Remote files and tasks are not deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (accepted == true) await controller.deleteProject(project.id);
  }
}

enum TaskListMode { projects, tasks }

final class TaskListPaneModel {
  const TaskListPaneModel({
    required this.projects,
    required this.selectedProjectId,
    required this.projectTasks,
    required this.unassignedTasks,
    required this.connected,
    this.recentTasks = const [],
    this.initialMode = TaskListMode.projects,
    this.selectedTaskId,
    this.connectionPhase = RemoteConnectionPhase.disconnected,
    this.unassignedExpanded = false,
    this.hasMoreProjectTasks = false,
    this.hasMoreRecentTasks = false,
    this.hasMoreUnassignedTasks = false,
    this.loadingProjectPage = false,
    this.loadingRecentTasks = false,
    this.loadingUnassignedPage = false,
  });

  final List<RemoteProject> projects;
  final String? selectedProjectId;
  final String? selectedTaskId;
  final List<TaskRecord> projectTasks;
  final List<TaskRecord> recentTasks;
  final List<TaskRecord> unassignedTasks;
  final bool connected;
  final TaskListMode initialMode;
  final RemoteConnectionPhase connectionPhase;
  final bool unassignedExpanded;
  final bool hasMoreProjectTasks;
  final bool hasMoreRecentTasks;
  final bool hasMoreUnassignedTasks;
  final bool loadingProjectPage;
  final bool loadingRecentTasks;
  final bool loadingUnassignedPage;

  RemoteProject? get selectedProject {
    for (final project in projects) {
      if (project.id == selectedProjectId) return project;
    }
    return null;
  }
}

class TaskListPane extends StatefulWidget {
  const TaskListPane({
    required this.model,
    this.onRefresh,
    this.onAddProject,
    this.onEditProject,
    this.onDeleteProject,
    this.onModeChanged,
    this.onProjectSelected,
    this.onNewTask,
    this.onTaskSelected,
    this.onToggleUnassigned,
    this.onLoadMoreProjectTasks,
    this.onLoadMoreRecentTasks,
    this.onLoadMoreUnassignedTasks,
    super.key,
  });

  final TaskListPaneModel model;
  final RefreshCallback? onRefresh;
  final VoidCallback? onAddProject;
  final VoidCallback? onEditProject;
  final VoidCallback? onDeleteProject;
  final ValueChanged<TaskListMode>? onModeChanged;
  final ValueChanged<String?>? onProjectSelected;
  final ValueChanged<TaskListMode>? onNewTask;
  final ValueChanged<String>? onTaskSelected;
  final VoidCallback? onToggleUnassigned;
  final VoidCallback? onLoadMoreProjectTasks;
  final VoidCallback? onLoadMoreRecentTasks;
  final VoidCallback? onLoadMoreUnassignedTasks;

  @override
  State<TaskListPane> createState() => _TaskListPaneState();
}

class _TaskListPaneState extends State<TaskListPane> {
  final _search = TextEditingController();
  late TaskListMode _mode;

  @override
  void initState() {
    super.initState();
    _mode = widget.model.initialMode;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final project = model.selectedProject;
    final projectTasks = _filtered(model.projectTasks);
    final recentTasks = _filtered(model.recentTasks);
    final unassignedTasks = _filtered(model.unassignedTasks);
    final canShowTasks = model.connected ||
        model.connectionPhase == RemoteConnectionPhase.reconnecting;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Workspace',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 3),
                    ConnectionBadge(phase: model.connectionPhase),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Refresh tasks',
                onPressed: model.connected ? widget.onRefresh : null,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: 'Add project',
                onPressed: model.connected && _mode == TaskListMode.projects
                    ? widget.onAddProject
                    : null,
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
              IconButton.filled(
                tooltip: 'New task',
                onPressed: model.connected
                    ? () => widget.onNewTask?.call(_mode)
                    : null,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<TaskListMode>(
              key: const Key('task-list-mode'),
              segments: const [
                ButtonSegment(
                  value: TaskListMode.projects,
                  icon: Icon(Icons.folder_outlined),
                  label: Text('Projects'),
                ),
                ButtonSegment(
                  value: TaskListMode.tasks,
                  icon: Icon(Icons.history),
                  label: Text('Tasks'),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: model.connected
                  ? (selection) {
                      final mode = selection.single;
                      setState(() => _mode = mode);
                      widget.onModeChanged?.call(mode);
                    }
                  : null,
            ),
          ),
        ),
        if (_mode == TaskListMode.projects)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(project?.id),
                    initialValue: project?.id,
                    decoration: const InputDecoration(
                      labelText: 'Project',
                      prefixIcon: Icon(Icons.folder_outlined),
                    ),
                    hint: const Text('No project selected'),
                    items: [
                      for (final item in model.projects)
                        DropdownMenuItem(value: item.id, child: Text(item.name)),
                    ],
                    onChanged:
                        model.connected ? widget.onProjectSelected : null,
                  ),
                ),
                IconButton(
                  tooltip: 'Edit project',
                  onPressed: model.connected && project != null
                      ? widget.onEditProject
                      : null,
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: 'Delete project',
                  onPressed: model.connected && project != null
                      ? widget.onDeleteProject
                      : null,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'Search tasks',
              prefixIcon: Icon(Icons.search),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: !canShowTasks
              ? const _ConnectPrompt()
              : RefreshIndicator(
                  onRefresh: widget.onRefresh ?? () async {},
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      if (_mode == TaskListMode.tasks) ...[
                        const _SectionHeader(
                          title: 'Recent tasks',
                          subtitle: 'Newest activity first',
                        ),
                        if (recentTasks.isEmpty)
                          const _EmptySection(message: 'No recent tasks')
                        else
                          for (final task in recentTasks)
                            _TaskRow(
                              task: task,
                              selected: model.selectedTaskId == task.id,
                              onTap: () => widget.onTaskSelected?.call(task.id),
                            ),
                        if (model.hasMoreRecentTasks ||
                            model.loadingRecentTasks)
                          _LoadMoreButton(
                            key: const Key('load-more-recent'),
                            loading: model.loadingRecentTasks,
                            onPressed: widget.onLoadMoreRecentTasks,
                          ),
                      ] else ...[
                        if (project == null)
                          const _NoProjectSelected()
                        else ...[
                          _SectionHeader(
                            title: project.name,
                            subtitle: project.cwd,
                          ),
                          if (projectTasks.isEmpty && model.loadingProjectPage)
                            const Padding(
                              padding: EdgeInsets.all(24),
                              child: Center(
                                child: CircularProgressIndicator(
                                  key: Key('project-head-progress'),
                                ),
                              ),
                            )
                          else if (projectTasks.isEmpty)
                            const _EmptySection(
                              message: 'No tasks in this project',
                            )
                          else
                            for (final task in projectTasks)
                              _TaskRow(
                                task: task,
                                selected: model.selectedTaskId == task.id,
                                onTap: () => widget.onTaskSelected?.call(task.id),
                              ),
                          if (projectTasks.isNotEmpty &&
                              (model.hasMoreProjectTasks ||
                                  model.loadingProjectPage))
                            _LoadMoreButton(
                              key: const Key('load-more-project'),
                              loading: model.loadingProjectPage,
                              onPressed: widget.onLoadMoreProjectTasks,
                            ),
                        ],
                        const Divider(height: 1),
                        ExpansionTile(
                          key: ValueKey(model.unassignedExpanded),
                          initiallyExpanded: model.unassignedExpanded,
                          leading: const Icon(Icons.inbox_outlined),
                          title: const Text('Unassigned'),
                          subtitle: Text(
                            '${model.unassignedTasks.length} recent tasks',
                          ),
                          onExpansionChanged: (_) =>
                              widget.onToggleUnassigned?.call(),
                          children: [
                            if (unassignedTasks.isEmpty)
                              const _EmptySection(
                                message:
                                    'No unassigned tasks in recent history',
                              )
                            else
                              for (final task in unassignedTasks)
                                _TaskRow(
                                  task: task,
                                  selected: model.selectedTaskId == task.id,
                                  onTap: () =>
                                      widget.onTaskSelected?.call(task.id),
                                ),
                            if (model.hasMoreUnassignedTasks ||
                                model.loadingUnassignedPage)
                              _LoadMoreButton(
                                key: const Key('load-more-unassigned'),
                                loading: model.loadingUnassignedPage,
                                onPressed: widget.onLoadMoreUnassignedTasks,
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  List<TaskRecord> _filtered(List<TaskRecord> tasks) {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return tasks;
    return tasks
        .where((task) =>
            task.title.toLowerCase().contains(query) ||
            task.cwd.toLowerCase().contains(query))
        .toList(growable: false);
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(title, style: Theme.of(context).textTheme.titleMedium),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      );
}

class _LoadMoreButton extends StatelessWidget {
  const _LoadMoreButton({
    required this.loading,
    required this.onPressed,
    super.key,
  });

  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: OutlinedButton(
          onPressed: loading ? null : onPressed,
          child: loading
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Load more'),
        ),
      );
}

class _EmptySection extends StatelessWidget {
  const _EmptySection({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text(message)),
      );
}

class _NoProjectSelected extends StatelessWidget {
  const _NoProjectSelected();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.create_new_folder_outlined, size: 36),
            SizedBox(height: 10),
            Text('Add or select a project to organize its tasks.'),
          ],
        ),
      );
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.task,
    required this.selected,
    required this.onTap,
  });

  final TaskRecord task;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        selected: selected,
        leading: _StatusIcon(status: task.status),
        title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (task.cwd.isNotEmpty)
              Text(task.cwd, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (task.ownership == TaskOwnership.external)
              Text(
                'Running in another client',
                style:
                    TextStyle(color: Theme.of(context).colorScheme.secondary),
              ),
          ],
        ),
        trailing: task.ownership == TaskOwnership.external
            ? const Icon(Icons.lock_outline, size: 18)
            : const Icon(Icons.chevron_right),
        onTap: onTap,
      );
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});

  final TaskStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      TaskStatus.running => Theme.of(context).colorScheme.primary,
      TaskStatus.failed => Theme.of(context).colorScheme.error,
      TaskStatus.interrupted => Theme.of(context).colorScheme.secondary,
      _ => Theme.of(context).colorScheme.outline,
    };
    return SizedBox.square(
      dimension: 24,
      child: status == TaskStatus.running
          ? CircularProgressIndicator(strokeWidth: 2.5, color: color)
          : Icon(Icons.circle_outlined, color: color, size: 20),
    );
  }
}

class _ConnectPrompt extends StatelessWidget {
  const _ConnectPrompt();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Connect an SSH host to load its Codex tasks.'),
        ),
      );
}

class _NoTaskSelected extends StatelessWidget {
  const _NoTaskSelected();

  @override
  Widget build(BuildContext context) => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 40),
            SizedBox(height: 12),
            Text('Select a task'),
          ],
        ),
      );
}
