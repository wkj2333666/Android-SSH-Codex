import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../app_controller.dart';
import '../attachments.dart';
import '../protocol/codex_remote_api.dart';
import '../tasks/task_message_queue.dart';
import '../tasks/task_reducer.dart';
import 'composer_completion.dart';
import 'task_timeline_render_cache.dart';
import 'timeline_entries.dart';
import 'turn_settings_picker.dart';
import 'widgets/timeline_item.dart';
import 'widgets/user_input_panel.dart';
import 'widgets/remote_file_actions.dart';

bool isTaskComposerInputEnabled({
  required TaskRecord task,
  required bool connected,
}) =>
    connected;

bool isTaskComposerSendEnabled({
  required TaskRecord task,
  required bool connected,
  required bool sending,
}) =>
    isTaskComposerInputEnabled(task: task, connected: connected) && !sending;

bool isTaskComposerEnabled({
  required TaskRecord task,
  required bool connected,
  required bool sending,
}) =>
    isTaskComposerSendEnabled(
      task: task,
      connected: connected,
      sending: sending,
    );

String restoreComposerDraft({
  required String currentText,
  required String submittedText,
}) =>
    currentText.isEmpty ? submittedText : currentText;

List<QueuedTaskMessage> visibleQueuedMessages(
  List<QueuedTaskMessage> messages,
  Set<String> inFlightMessageIds,
) =>
    messages
        .where((message) => !inFlightMessageIds.contains(message.id))
        .toList(growable: false);

class TaskView extends StatefulWidget {
  const TaskView({required this.controller, required this.task, super.key});

  final AppController controller;
  final TaskRecord task;

  @override
  State<TaskView> createState() => _TaskViewState();
}

class _TaskViewState extends State<TaskView> {
  final _composer = TextEditingController();
  final _timelineCache = TaskTimelineRenderCache<Widget>();
  var _sending = false;
  TaskSendMode _sendMode = TaskSendMode.auto;
  var _commandBusy = false;
  var _queueActionBusy = false;
  var _lastCommandSucceeded = true;
  RemoteSkill? _selectedSkill;
  TurnSettings _turnSettings = const TurnSettings();
  List<RemoteSkill>? _availableSkills;
  List<ComposerCompletion> _completions = const [];
  var _loadingSkills = false;
  var _pickingAttachment = false;
  List<LocalAttachment> _attachments = [];

  @override
  void initState() {
    super.initState();
    _composer.addListener(_updateCompletions);
  }

  @override
  void didUpdateWidget(covariant TaskView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.id != widget.task.id) {
      _timelineCache.clear();
      _composer.clear();
      _selectedSkill = null;
      _turnSettings = const TurnSettings();
      _availableSkills = null;
      _completions = const [];
      _sending = false;
      _sendMode = TaskSendMode.auto;
      _commandBusy = false;
      _queueActionBusy = false;
      _attachments = [];
    }
  }

  @override
  void dispose() {
    _composer
      ..removeListener(_updateCompletions)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final compact = MediaQuery.sizeOf(context).width < 800;
    final approvals = widget.controller.approvals
        .where((approval) => approval.threadId == task.id)
        .toList(growable: false);
    final queuedMessages = visibleQueuedMessages(
      widget.controller.queuedMessagesForTask(task.id),
      widget.controller.inFlightQueuedMessageIdsForTask(task.id),
    );
    final timelineState = TaskTimelineRenderState(
      items: task.items,
      owner: widget.controller,
      loading: widget.controller.isTaskDetailLoading(task.id),
      error: widget.controller.taskDetailError(task.id),
      hasOlder: widget.controller.hasOlderTaskContext,
      loadingOlder: widget.controller.isLoadingOlderTaskContext,
      olderError: widget.controller.olderTaskContextError,
    );
    final timeline = _timelineCache.resolve(
      timelineState,
      () => TaskTimeline(
        loadImage: widget.controller.loadAttachmentImage,
        items: timelineState.items,
        loading: timelineState.loading,
        error: timelineState.error,
        onRetry: widget.controller.retrySelectedTaskDetails,
        hasOlder: timelineState.hasOlder,
        loadingOlder: timelineState.loadingOlder,
        olderError: timelineState.olderError,
        onLoadOlder: widget.controller.loadOlderSelectedTaskContext,
      ),
    );
    final content = Column(
      children: [
        _TaskHeader(
          controller: widget.controller,
          task: task,
          commandBusy: _commandBusy,
          onCommand: _handleCommand,
        ),
        const Divider(height: 1),
        Expanded(
            child: RemoteFileActions(
                download: widget.controller.downloadFile,
                downloadWithProgress: widget.controller.downloadFile,
                cancelDownload: widget.controller.cancelDownload,
                child: timeline)),
        if (widget.controller.userInputRequests
            .any((r) => r.threadId == task.id))
          ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: (MediaQuery.sizeOf(context).height -
                        MediaQuery.viewInsetsOf(context).bottom) *
                    0.4),
            child: SingleChildScrollView(
              child: Column(children: [
                for (final request in widget.controller.userInputRequests
                    .where((r) => r.threadId == task.id))
                  UserInputPanel(
                    key: ObjectKey(request),
                    request: request,
                    onAnswer: (answers) =>
                        widget.controller.answerUserInput(request, answers),
                  ),
              ]),
            ),
          ),
        for (final approval in approvals)
          _ApprovalBar(
            approval: approval,
            enabled: widget.controller.isConnected,
            onDecision: (decision) =>
                widget.controller.answerApproval(approval, decision),
          ),
        if (queuedMessages.isNotEmpty)
          QueuedMessagePanel(
            messages: queuedMessages,
            enabled: widget.controller.isConnected && !_queueActionBusy,
            onSteer: _steerQueuedMessage,
            onRemove: _removeQueuedMessage,
          ),
        if (_selectedSkill case final skill?)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: InputChip(
                avatar: const Icon(Icons.auto_awesome, size: 18),
                label: Text('\$${skill.name}'),
                tooltip: skill.description.isEmpty ? null : skill.description,
                onDeleted: _sending
                    ? null
                    : () => setState(() => _selectedSkill = null),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: TurnSettingsPicker(
            models: widget.controller.models,
            value: resolveTurnSettings(widget.controller.models, _turnSettings,
                model: task.model,
                effort: task.reasoningEffort,
                useCatalogDefault: false),
            useCatalogDefault: false,
            enabled: widget.controller.isConnected && !_sending,
            onChanged: (value) => setState(() => _turnSettings = value),
          ),
        ),
        const Divider(height: 1),
        if (_attachments.isNotEmpty)
          SizedBox(
            height: 64,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final attachment in _attachments)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InputChip(
                      avatar: attachment.isImage
                          ? Image.memory(attachment.bytes,
                              width: 32,
                              height: 32,
                              cacheWidth: 64,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.broken_image))
                          : const Icon(Icons.insert_drive_file_outlined),
                      label: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: Text(attachment.name,
                            overflow: TextOverflow.ellipsis),
                      ),
                      onPressed: attachment.isImage
                          ? () => _previewAttachment(attachment)
                          : null,
                      onDeleted: () =>
                          setState(() => _attachments.remove(attachment)),
                    ),
                  ),
              ],
            ),
          ),
        if (_sending || _pickingAttachment)
          const LinearProgressIndicator(minHeight: 2),
        _Composer(
          controller: _composer,
          inputEnabled: isTaskComposerInputEnabled(
            task: task,
            connected: widget.controller.isConnected,
          ),
          sendEnabled: isTaskComposerSendEnabled(
            task: task,
            connected: widget.controller.isConnected,
            sending: _sending,
          ),
          completions: _completions,
          loadingCompletions: _loadingSkills,
          onCompletion: _selectCompletion,
          onSend: _send,
          sendMode: _sendMode,
          onSendModeChanged: (mode) => setState(() => _sendMode = mode),
          onAttach: Attachments.supported &&
                  !_sending &&
                  !_pickingAttachment &&
                  widget.controller.isConnected
              ? _pickAttachment
              : null,
        ),
      ],
    );
    return PopScope(
      canPop: !compact,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && compact) widget.controller.clearSelectedTask();
      },
      child: content,
    );
  }

  Future<void> _send() async {
    if (_sending) return;
    final submittedText = _composer.text;
    final text = submittedText.trim();
    if (text.isEmpty && _attachments.isEmpty) return;
    final taskId = widget.task.id;
    final submittedAttachments = List<LocalAttachment>.of(_attachments);
    final submittedSkill = _selectedSkill;
    final settings = resolveTurnSettings(
        widget.controller.models, _turnSettings,
        model: widget.task.model,
        effort: widget.task.reasoningEffort,
        useCatalogDefault: false);
    setState(() {
      _sending = true;
      _selectedSkill = null;
      _completions = const [];
      _attachments = [];
    });
    _composer.clear();
    try {
      final disposition = await widget.controller.sendPrompt(
        text,
        mode: _sendMode,
        skill: submittedSkill,
        model: settings.model,
        effort: settings.effort,
        attachments: submittedAttachments,
      );
      if (!mounted || widget.task.id != taskId) return;
      if (disposition == TaskMessageDisposition.queued) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message queued for the next turn.')),
        );
      }
    } catch (exception) {
      if (mounted && widget.task.id == taskId) {
        setState(() => _attachments = submittedAttachments);
        final restored = restoreComposerDraft(
          currentText: _composer.text,
          submittedText: submittedText,
        );
        if (restored != _composer.text) {
          _composer.value = TextEditingValue(
            text: restored,
            selection: TextSelection.collapsed(offset: restored.length),
          );
        }
        if (_selectedSkill == null && submittedSkill != null) {
          setState(() => _selectedSkill = submittedSkill);
        }
      }
      _showError(exception);
    } finally {
      if (mounted && widget.task.id == taskId) setState(() => _sending = false);
    }
  }

  Future<void> _pickAttachment(bool image) async {
    if (_attachments.length >= Attachments.maxCount) {
      _showError('Up to 4 attachments per message.');
      return;
    }
    final taskId = widget.task.id;
    setState(() => _pickingAttachment = true);
    try {
      final picked = await Attachments.pick(image: image);
      if (!mounted || widget.task.id != taskId || picked == null) return;
      final files = [..._attachments, picked];
      Attachments.validate(files);
      setState(() => _attachments = files);
    } catch (error) {
      if (mounted && widget.task.id == taskId) _showError(error);
    } finally {
      if (mounted) setState(() => _pickingAttachment = false);
    }
  }

  Future<void> _previewAttachment(LocalAttachment attachment) async {
    await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                    child: InteractiveViewer(
                        child: Image.memory(attachment.bytes,
                            cacheWidth: 1200,
                            errorBuilder: (_, __, ___) =>
                                const Text('Cannot preview image')))),
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close')),
              ]),
            ));
  }

  Future<void> _steerQueuedMessage(String messageId) => _runQueueAction(
        () => widget.controller.steerQueuedMessage(widget.task.id, messageId),
      );

  Future<void> _removeQueuedMessage(String messageId) => _runQueueAction(
        () => widget.controller.removeQueuedMessage(widget.task.id, messageId),
      );

  Future<void> _runQueueAction(Future<void> Function() operation) async {
    if (_queueActionBusy) return;
    setState(() => _queueActionBusy = true);
    try {
      await operation();
    } catch (exception) {
      _showError(exception);
    } finally {
      if (mounted) setState(() => _queueActionBusy = false);
    }
  }

  Future<void> _handleCommand(TaskCommand command) async {
    switch (command) {
      case TaskCommand.skills:
        await _chooseSkill();
      case TaskCommand.goal:
        await _editGoal();
      case TaskCommand.compact:
        await _compactTask();
      case TaskCommand.interrupt:
        await _runCommand(widget.controller.interruptSelectedTask);
    }
  }

  Future<void> _chooseSkill() async {
    final skills =
        await _runCommand(widget.controller.listSkillsForSelectedTask);
    if (!mounted || skills == null) return;
    _availableSkills = skills;
    final selected = await showDialog<RemoteSkill>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose a skill'),
        content: SizedBox(
          width: 480,
          child: skills.isEmpty
              ? const Text('No enabled skills are available for this project.')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: skills.length,
                  itemBuilder: (context, index) {
                    final skill = skills[index];
                    return ListTile(
                      leading: const Icon(Icons.auto_awesome),
                      title: Text('\$${skill.name}'),
                      subtitle: skill.description.isEmpty
                          ? null
                          : Text(skill.description),
                      onTap: () => Navigator.pop(context, skill),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (mounted && selected != null) {
      setState(() => _selectedSkill = selected);
    }
  }

  void _updateCompletions() {
    if (!mounted) return;
    final cursor = _composer.selection.baseOffset;
    final completions = composerCompletions(
      _composer.text,
      cursor,
      _availableSkills ?? const [],
    );
    setState(() => _completions = completions.take(6).toList(growable: false));
    if (_availableSkills == null &&
        !_loadingSkills &&
        hasActiveSkillCompletion(_composer.text, cursor)) {
      _loadCompletionSkills();
    }
  }

  Future<void> _loadCompletionSkills() async {
    final taskId = widget.task.id;
    setState(() => _loadingSkills = true);
    try {
      final skills = await widget.controller.listSkillsForSelectedTask();
      if (!mounted || widget.task.id != taskId) return;
      _availableSkills = skills;
      _updateCompletions();
    } catch (exception) {
      _showError(exception);
    } finally {
      if (mounted) setState(() => _loadingSkills = false);
    }
  }

  Future<void> _selectCompletion(ComposerCompletion completion) async {
    final current = composerCompletions(
      _composer.text,
      _composer.selection.baseOffset,
      _availableSkills ?? const [],
    ).any(
      (candidate) =>
          candidate.kind == completion.kind &&
          candidate.value == completion.value,
    );
    if (!current) {
      setState(() => _completions = const []);
      return;
    }
    final edit = removeActiveCompletionToken(
      _composer.text,
      _composer.selection.baseOffset,
    );
    _composer.value = TextEditingValue(
      text: edit.text,
      selection: TextSelection.collapsed(offset: edit.cursor),
    );
    setState(() => _completions = const []);
    if (completion.kind == ComposerCompletionKind.skill) {
      RemoteSkill? skill;
      for (final candidate in _availableSkills ?? const <RemoteSkill>[]) {
        if (r'$' + candidate.name == completion.value) {
          skill = candidate;
          break;
        }
      }
      if (skill != null) setState(() => _selectedSkill = skill);
      return;
    }
    final command = switch (completion.value) {
      '/goal' => TaskCommand.goal,
      '/compact' => TaskCommand.compact,
      '/skills' => TaskCommand.skills,
      '/interrupt' => TaskCommand.interrupt,
      _ => null,
    };
    if (command != null) await _handleCommand(command);
  }

  Future<void> _editGoal() async {
    final current = await _runCommand(widget.controller.readSelectedGoal);
    if (!mounted || !_lastCommandSucceeded) return;
    final objective = TextEditingController(text: current?.objective ?? '');
    final budget = TextEditingController(
      text: current?.tokenBudget?.toString() ?? '',
    );
    final action = await showDialog<_GoalAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Task goal'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: objective,
                autofocus: true,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Objective',
                  hintText: 'What should this task accomplish?',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: budget,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Token budget (optional)',
                ),
              ),
              if (current != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${current.status} · ${current.tokensUsed} tokens · '
                    '${current.timeUsedSeconds}s',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (current != null)
            TextButton(
              onPressed: () => Navigator.pop(context, _GoalAction.clear),
              child: const Text('Clear goal'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _GoalAction.save),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) {
      objective.dispose();
      budget.dispose();
      return;
    }
    if (action == _GoalAction.clear) {
      await _runCommand(widget.controller.clearSelectedGoal);
    } else {
      final tokenBudget =
          budget.text.trim().isEmpty ? null : int.tryParse(budget.text.trim());
      if (budget.text.trim().isNotEmpty && tokenBudget == null) {
        _showError('Token budget must be a whole number.');
      } else {
        await _runCommand(
          () => widget.controller.setSelectedGoal(
            objective: objective.text,
            tokenBudget: tokenBudget,
          ),
        );
      }
    }
    objective.dispose();
    budget.dispose();
  }

  Future<void> _compactTask() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Compact context?'),
        content: const Text(
          'Codex will summarize older context to make more room in this task.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Compact'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _runCommand(widget.controller.compactSelectedTask);
    }
  }

  Future<T?> _runCommand<T>(Future<T> Function() operation) async {
    if (_commandBusy) return null;
    setState(() {
      _commandBusy = true;
      _lastCommandSucceeded = true;
    });
    try {
      return await operation();
    } catch (exception) {
      _lastCommandSucceeded = false;
      _showError(exception);
      return null;
    } finally {
      if (mounted) setState(() => _commandBusy = false);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.toString())),
    );
  }
}

enum _GoalAction { save, clear }

enum TaskCommand { skills, goal, compact, interrupt }

class QueuedMessagePanel extends StatelessWidget {
  const QueuedMessagePanel({
    required this.messages,
    required this.enabled,
    required this.onSteer,
    required this.onRemove,
    super.key,
  });

  final List<QueuedTaskMessage> messages;
  final bool enabled;
  final Future<void> Function(String messageId) onSteer;
  final Future<void> Function(String messageId) onRemove;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          border: Border(
            top: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.schedule, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Queued messages (${messages.length})',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: messages.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    final metadata = [
                      if (message.model case final model?) model,
                      if (message.effort case final effort?) effort,
                    ].join(' / ');
                    return Row(
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  message.text,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (metadata.isNotEmpty)
                                  Text(
                                    metadata,
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                              ],
                            ),
                          ),
                        ),
                        Tooltip(
                        message: 'Steer queued message',
                        child: TextButton.icon(
                          onPressed:
                              enabled ? () async => onSteer(message.id) : null,
                          icon: const Icon(Icons.redo, size: 18),
                          label: const Text('Steer'),
                        ),
                        ),
                        IconButton(
                          tooltip: 'Remove queued message',
                          onPressed:
                              enabled ? () async => onRemove(message.id) : null,
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
}

class TaskCommandMenu extends StatelessWidget {
  const TaskCommandMenu({
    required this.enabled,
    required this.onSelected,
    super.key,
  });

  final bool enabled;
  final ValueChanged<TaskCommand> onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<TaskCommand>(
        enabled: enabled,
        tooltip: 'Task commands',
        onSelected: onSelected,
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: TaskCommand.skills,
            child: ListTile(
              leading: Icon(Icons.auto_awesome),
              title: Text('Skills'),
            ),
          ),
          PopupMenuItem(
            value: TaskCommand.goal,
            child: ListTile(
              leading: Icon(Icons.flag_outlined),
              title: Text('Goal'),
            ),
          ),
          PopupMenuItem(
            value: TaskCommand.compact,
            child: ListTile(
              leading: Icon(Icons.compress),
              title: Text('Compact context'),
            ),
          ),
          PopupMenuItem(
            value: TaskCommand.interrupt,
            child: ListTile(
              leading: Icon(Icons.stop_circle_outlined),
              title: Text('Interrupt turn'),
            ),
          ),
        ],
        icon: const Icon(Icons.more_vert),
      );
}

class TaskTimeline extends StatefulWidget {
  const TaskTimeline({
    required this.items,
    this.loading = false,
    this.error,
    this.onRetry,
    this.hasOlder = false,
    this.loadingOlder = false,
    this.olderError,
    this.onLoadOlder,
    this.loadImage,
    super.key,
  });

  final List<TaskItem> items;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;
  final bool hasOlder;
  final bool loadingOlder;
  final String? olderError;
  final Future<void> Function()? onLoadOlder;
  final Future<Uint8List> Function(String)? loadImage;

  @override
  State<TaskTimeline> createState() => _TaskTimelineState();
}

class _TaskTimelineState extends State<TaskTimeline>
    with WidgetsBindingObserver {
  static const _followThreshold = 1.0;
  static const _olderLoadThreshold = 200.0;

  final _scrollController = ScrollController();
  var _followLatest = true;
  var _showJumpToLatest = false;
  var _requestingOlder = false;
  var _olderLoadArmed = true;
  var _olderCheckScheduled = false;
  // A long run of collapsed tool events may never fill the viewport.
  var _automaticPagesSinceGesture = 0;
  double? _pendingOlderAnchorOffset;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    _scheduleLatest(animated: false);
    _scheduleOlderCheck();
  }

  @override
  void didChangeMetrics() {
    if (_followLatest) _scheduleLatest(animated: false);
    _scheduleOlderCheck();
  }

  @override
  void didUpdateWidget(covariant TaskTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items != widget.items ||
        (oldWidget.loadingOlder && !widget.loadingOlder) ||
        oldWidget.hasOlder != widget.hasOlder) {
      _olderLoadArmed = true;
    }
    _scheduleOlderCheck();
    if (oldWidget.items != widget.items ||
        oldWidget.loading != widget.loading ||
        oldWidget.error != widget.error) {
      _scheduleLatest(animated: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    _checkOlderContext();
    final awayFromLatest = _distanceFromLatest > _followThreshold;
    final showJump = awayFromLatest && !_followLatest;
    if (showJump == _showJumpToLatest) return;
    setState(() => _showJumpToLatest = showJump);
  }

  void _scheduleOlderCheck() {
    if (_olderCheckScheduled) return;
    _olderCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _olderCheckScheduled = false;
      if (mounted) _checkOlderContext();
    });
  }

  void _checkOlderContext() {
    if (!_scrollController.hasClients ||
        _requestingOlder ||
        widget.loadingOlder) {
      return;
    }
    if (_automaticPagesSinceGesture >= 10) return;
    final distanceFromOldest = _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    if (distanceFromOldest > _olderLoadThreshold) {
      _olderLoadArmed = true;
    } else if (_olderLoadArmed) {
      _olderLoadArmed = false;
      _loadOlder();
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    // Nested horizontal code-block scrolling must not affect timeline follow.
    if (notification.depth != 0) return false;
    if ((notification is ScrollStartNotification &&
            notification.dragDetails != null) ||
        (notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle)) {
      // Pause at gesture start, before a streaming update can animate us back.
      _automaticPagesSinceGesture = 0;
      _olderLoadArmed = true;
      setState(() => _followLatest = false);
      return false;
    }
    if (notification is ScrollEndNotification) {
      final atLatest = _distanceFromLatest <= _followThreshold;
      setState(() {
        _followLatest = atLatest;
        _showJumpToLatest = !atLatest;
      });
      return false;
    }
    final userDriven = notification is ScrollUpdateNotification &&
        notification.dragDetails != null;
    final userOverscroll = notification is OverscrollNotification &&
        notification.dragDetails != null;
    if (!userDriven && !userOverscroll) return false;
    if (_requestingOlder) {
      _pendingOlderAnchorOffset = _scrollController.position.pixels;
    }
    const followLatest = false;
    if (followLatest == _followLatest && _showJumpToLatest == !followLatest) {
      return false;
    }
    setState(() {
      _followLatest = followLatest;
      _showJumpToLatest = !followLatest;
    });
    return false;
  }

  Future<void> _loadOlder({bool retry = false}) async {
    final load = widget.onLoadOlder;
    if (load == null ||
        _requestingOlder ||
        widget.loadingOlder ||
        !widget.hasOlder ||
        (!retry && widget.olderError != null) ||
        !_scrollController.hasClients) {
      return;
    }
    _pendingOlderAnchorOffset = _scrollController.position.pixels;
    if (retry) _automaticPagesSinceGesture = 0;
    _automaticPagesSinceGesture++;
    setState(() => _requestingOlder = true);
    try {
      await load();
      final anchorOffset = _pendingOlderAnchorOffset;
      if (anchorOffset != null) {
        _preserveReverseAnchor(anchorOffset, attempts: 3);
      }
    } finally {
      _pendingOlderAnchorOffset = null;
      if (mounted) setState(() => _requestingOlder = false);
      if (mounted) _scheduleOlderCheck();
    }
  }

  void _preserveReverseAnchor(double offset, {required int attempts}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(offset);
      if (attempts > 1) {
        _preserveReverseAnchor(offset, attempts: attempts - 1);
      }
    });
  }

  double get _distanceFromLatest =>
      _scrollController.position.pixels -
      _scrollController.position.minScrollExtent;

  void _scheduleLatest({required bool animated}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_followLatest || !_scrollController.hasClients) return;
      _scrollToLatest(animated: animated);
    });
  }

  void _scrollToLatest({bool animated = true}) {
    if (!_scrollController.hasClients) return;
    setState(() {
      _followLatest = true;
      _showJumpToLatest = false;
    });
    final latest = _scrollController.position.minScrollExtent;
    if (animated) {
      _scrollController.animateTo(
        latest,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(latest);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (widget.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 10),
              Text(widget.error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: widget.onRetry,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (widget.items.isEmpty && !widget.hasOlder) {
      return const Center(child: Text('No task events yet'));
    }
    final entries = buildTimelineEntries(widget.items);
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (notification) {
              if (notification.depth == 0) _scheduleOlderCheck();
              return false;
            },
            child: SelectionArea(
              child: ListView.builder(
                controller: _scrollController,
                reverse: true,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 72),
                itemCount: entries.length + 1,
                itemBuilder: (_, index) {
                  if (index == entries.length) {
                    return _OlderContextControl(
                      loading: widget.loadingOlder || _requestingOlder,
                      error: widget.olderError,
                      hasOlder: widget.hasOlder,
                      onRetry: () => _loadOlder(retry: true),
                    );
                  }
                  return switch (entries[entries.length - index - 1]) {
                    TimelineMessageEntry(:final item) =>
                      TimelineItemView(item: item, loadImage: widget.loadImage),
                    TimelineActivityEntry(:final items) =>
                      TimelineActivityGroup(items: items),
                  };
                },
              ),
            ),
          ),
        ),
        if (_showJumpToLatest)
          Positioned(
            right: 16,
            bottom: 14,
            child: FloatingActionButton.small(
              key: const Key('jump-to-latest'),
              tooltip: 'Jump to latest',
              onPressed: _scrollToLatest,
              child: const Icon(Icons.arrow_downward),
            ),
          ),
      ],
    );
  }
}

class _OlderContextControl extends StatelessWidget {
  const _OlderContextControl({
    required this.loading,
    required this.error,
    required this.hasOlder,
    required this.onRetry,
  });

  final bool loading;
  final String? error;
  final bool hasOlder;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 44,
        child: Center(
          child: loading
              ? const SizedBox.square(
                  key: Key('older-context-progress'),
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : error != null
                  ? TextButton.icon(
                      key: const Key('retry-older-context'),
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Retry earlier context'),
                    )
                  : !hasOlder
                      ? Text(
                          'Start of task',
                          style: Theme.of(context).textTheme.bodySmall,
                        )
                      : TextButton(
                          key: const Key('load-older-context'),
                          onPressed: onRetry,
                          child: const Text('Load earlier context'),
                        ),
        ),
      );
}

class _TaskHeader extends StatelessWidget {
  const _TaskHeader({
    required this.controller,
    required this.task,
    required this.commandBusy,
    required this.onCommand,
  });

  final AppController controller;
  final TaskRecord task;
  final bool commandBusy;
  final ValueChanged<TaskCommand> onCommand;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
        child: Row(
          children: [
            if (MediaQuery.sizeOf(context).width < 800)
              IconButton(
                tooltip: 'Back to tasks',
                onPressed: controller.clearSelectedTask,
                icon: const Icon(Icons.arrow_back),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (task.cwd.isNotEmpty)
                    Text(
                      task.cwd,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            if (task.status == TaskStatus.running ||
                task.status == TaskStatus.queued)
              IconButton(
                tooltip: 'Interrupt turn',
                onPressed: controller.isConnected && !commandBusy
                    ? () => onCommand(TaskCommand.interrupt)
                    : null,
                icon: const Icon(Icons.stop_circle_outlined),
              ),
            TaskCommandMenu(
              enabled: controller.isConnected && !commandBusy,
              onSelected: onCommand,
            ),
          ],
        ),
      );
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.inputEnabled,
    required this.sendEnabled,
    required this.completions,
    required this.loadingCompletions,
    required this.onCompletion,
    required this.onSend,
    required this.sendMode,
    required this.onSendModeChanged,
    this.onAttach,
  });

  final TextEditingController controller;
  final bool inputEnabled;
  final bool sendEnabled;
  final List<ComposerCompletion> completions;
  final bool loadingCompletions;
  final ValueChanged<ComposerCompletion> onCompletion;
  final VoidCallback onSend;
  final TaskSendMode sendMode;
  final ValueChanged<TaskSendMode> onSendModeChanged;
  final ValueChanged<bool>? onAttach;

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SendModePicker(
                  value: sendMode,
                  enabled: sendEnabled,
                  onChanged: onSendModeChanged,
                ),
              ),
              if (completions.isNotEmpty || loadingCompletions)
                _CompletionPicker(
                  completions: completions,
                  loading: loadingCompletions,
                  onSelected: onCompletion,
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (Attachments.supported)
                    PopupMenuButton<bool>(
                      tooltip: 'Attach image or file',
                      enabled: onAttach != null,
                      onSelected: onAttach,
                      icon: const Icon(Icons.attach_file),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: true, child: Text('Image')),
                        PopupMenuItem(value: false, child: Text('File')),
                      ],
                    ),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      enabled: inputEnabled,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText:
                            inputEnabled ? 'Message Codex' : 'Read-only task',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: switch (sendMode) {
                      TaskSendMode.auto => 'Send message',
                      TaskSendMode.steer => 'Steer current turn',
                      TaskSendMode.queue => 'Queue message',
                    },
                    onPressed: sendEnabled ? onSend : null,
                    icon: Icon(switch (sendMode) {
                      TaskSendMode.auto => Icons.arrow_upward,
                      TaskSendMode.steer => Icons.redo,
                      TaskSendMode.queue => Icons.schedule,
                    }),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}

class SendModePicker extends StatelessWidget {
  const SendModePicker({required this.value, required this.enabled,
    required this.onChanged, super.key});
  final TaskSendMode value;
  final bool enabled;
  final ValueChanged<TaskSendMode> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<TaskSendMode>(
    tooltip: 'Message delivery mode',
    enabled: enabled,
    initialValue: value,
    onSelected: onChanged,
    itemBuilder: (_) => const [
      PopupMenuItem(value: TaskSendMode.auto,
        child: Text('Auto — start or steer')),
      PopupMenuItem(value: TaskSendMode.steer,
        child: Text('Steer — guide the current turn')),
      PopupMenuItem(value: TaskSendMode.queue,
        child: Text('Queue — send when idle')),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(switch (value) {
          TaskSendMode.auto => 'Auto',
          TaskSendMode.steer => 'Steer current turn',
          TaskSendMode.queue => 'Queue for next turn',
        }),
        const Icon(Icons.arrow_drop_down, size: 20),
      ]),
    ),
  );
}

class _CompletionPicker extends StatelessWidget {
  const _CompletionPicker({
    required this.completions,
    required this.loading,
    required this.onSelected,
  });

  final List<ComposerCompletion> completions;
  final bool loading;
  final ValueChanged<ComposerCompletion> onSelected;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: loading && completions.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: completions.length,
                  itemBuilder: (context, index) {
                    final completion = completions[index];
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        completion.kind == ComposerCompletionKind.skill
                            ? Icons.auto_awesome
                            : Icons.keyboard_command_key,
                      ),
                      title: Text(completion.value),
                      subtitle: completion.description.isEmpty
                          ? null
                          : Text(
                              completion.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      onTap: () => onSelected(completion),
                    );
                  },
                ),
        ),
      );
}

class _ApprovalBar extends StatelessWidget {
  const _ApprovalBar({
    required this.approval,
    required this.enabled,
    required this.onDecision,
  });

  final PendingApproval approval;
  final bool enabled;
  final ValueChanged<String> onDecision;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(approval.title,
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                approval.detail,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: enabled ? () => onDecision('decline') : null,
                    child: const Text('Deny'),
                  ),
                  FilledButton(
                    onPressed: enabled ? () => onDecision('accept') : null,
                    child: const Text('Allow once'),
                  ),
                  if (approval.availableDecisions.contains('acceptForSession'))
                    FilledButton.tonal(
                      onPressed:
                          enabled ? () => onDecision('acceptForSession') : null,
                      child: const Text('Allow for session'),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
}
