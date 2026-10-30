import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../app_controller.dart';
import '../attachments.dart';
import '../protocol/codex_remote_api.dart';
import '../tasks/task_message_queue.dart';
import '../tasks/task_reducer.dart';
import '../tasks/task_draft.dart';
import 'composer_completion.dart';
import 'task_timeline_render_cache.dart';
import 'timeline_entries.dart';
import 'turn_settings_picker.dart';
import 'widgets/timeline_item.dart';
import 'widgets/user_input_panel.dart';
import 'widgets/remote_file_actions.dart';
import 'widgets/task_question_panel.dart';
import 'task_manager.dart';

bool isTaskComposerInputEnabled({
  required TaskRecord task,
  required bool connected,
}) =>
    true;

bool isTaskComposerSendEnabled({
  required TaskRecord task,
  required bool connected,
  required bool sending,
  bool attachmentsReady = true,
}) =>
    !sending && attachmentsReady;

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

final class _SectorProgressPainter extends CustomPainter {
  const _SectorProgressPainter(this.progress, this.color);

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final rect = Offset.zero & size;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * progress.clamp(0.0, 1.0),
      true,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_SectorProgressPainter oldDelegate) =>
      progress != oldDelegate.progress || color != oldDelegate.color;
}

class _TaskViewState extends State<TaskView> {
  late TaskDraft _draft;
  TextEditingController get _composer => _draft.composer;
  final _composerFocus = FocusNode();
  final _timelineCache = TaskTimelineRenderCache<Widget>();
  bool get _sending => _draft.sending;
  set _sending(bool value) => _draft.sending = value;
  TaskSendMode get _sendMode => _draft.sendMode;
  set _sendMode(TaskSendMode value) => _draft.sendMode = value;
  var _commandBusy = false;
  var _queueActionBusy = false;
  var _lastCommandSucceeded = true;
  RemoteSkill? get _selectedSkill => _draft.skill;
  set _selectedSkill(RemoteSkill? value) => _draft.skill = value;
  TurnSettings get _turnSettings => _draft.settings;
  List<RemoteSkill>? _availableSkills;
  List<ComposerCompletion> _completions = const [];
  var _loadingSkills = false;
  bool get _pickingAttachment => _draft.picking;
  List<AttachmentTransfer> get _attachments => _draft.attachments;
  final Set<String> _answeredQuestionItemIds = {};

  @override
  void initState() {
    super.initState();
    _bindDraft();
  }

  @override
  void didUpdateWidget(covariant TaskView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.controller.draftForTask(widget.task.id);
    if (!identical(next, _draft)) {
      _unbindDraft();
      _bindDraft();
      _timelineCache.clear();
      _availableSkills = null;
      _completions = const [];
      _commandBusy = false;
      _queueActionBusy = false;
      _answeredQuestionItemIds.clear();
    }
  }

  void _bindDraft() {
    _draft = widget.controller.draftForTask(widget.task.id);
    _composer.addListener(_updateCompletions);
    _draft.addListener(_draftChanged);
  }

  void _unbindDraft() {
    _composer.removeListener(_updateCompletions);
    _draft.removeListener(_draftChanged);
  }

  void _draftChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _unbindDraft();
    _composerFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final draft = _draft;
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
      hasOlder: widget.controller.isConnected &&
          widget.controller.hasOlderTaskContext,
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
        answeredQuestionItemIds: _answeredQuestionItemIds,
        onAnswerQuestions: _answerTaskQuestions,
        onTurnAction: _turnAction,
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
        if (!widget.controller.isConnected)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Text('Offline · Showing cached messages',
                style: TextStyle(fontSize: 12)),
          ),
        Expanded(
            child: RemoteFileActions(
                download: widget.controller.downloadFile,
                downloadWithProgress: widget.controller.downloadFile,
                previewVideo: Attachments.supported
                    ? widget.controller.previewVideo
                    : null,
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
            deliveryState: widget.controller.deliveryState,
            onRetry: _retryQueuedMessage,
          ),
        if (widget.controller.selectedGoal case final goal?)
          ListTile(
            dense: true,
            visualDensity: const VisualDensity(vertical: -4),
            leading: const Icon(Icons.flag_outlined, size: 18),
            title: Text(goal.objective,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${goal.status} · ${goal.tokensUsed}'
                '${goal.tokenBudget == null ? '' : ' / ${goal.tokenBudget}'} tokens'),
            onTap: widget.controller.isConnected && !_commandBusy
                ? _editGoal
                : null,
            trailing: goal.status != 'complete'
                ? IconButton(
                    tooltip:
                        goal.status == 'active' ? 'Pause goal' : 'Resume goal',
                    icon: Icon(goal.status == 'active'
                        ? Icons.pause
                        : Icons.play_arrow),
                    onPressed: widget.controller.isConnected && !_commandBusy
                        ? () => _runCommand(() => widget.controller
                            .setGoalPaused(goal.status == 'active'))
                        : null)
                : null,
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
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(children: [
            Expanded(
                child: TurnSettingsPicker(
              accountUsage: widget.controller.accountUsage,
              models: widget.controller.models,
              value: resolveTurnSettings(
                  widget.controller.models, _turnSettings,
                  model: task.model,
                  effort: task.reasoningEffort,
                  useCatalogDefault: false),
              useCatalogDefault: false,
              enabled: !_sending,
              onChanged: (value) {
                if (draft.disposed) return;
                draft.settings = value;
                draft.changed();
              },
            )),
            SendModePicker(
              value: _sendMode,
              enabled: !_sending,
              onChanged: (mode) {
                setState(() => _sendMode = mode);
                _draft.changed();
              },
              compact: true,
            ),
          ]),
        ),
        const Divider(height: 1),
        if (_attachments.isNotEmpty)
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final attachment in _attachments)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _attachmentChip(attachment),
                  ),
              ],
            ),
          ),
        if (_sending || _pickingAttachment)
          const LinearProgressIndicator(minHeight: 2),
        _Composer(
          controller: _composer,
          focusNode: _composerFocus,
          inputEnabled: isTaskComposerInputEnabled(
            task: task,
            connected: widget.controller.isConnected,
          ),
          sendEnabled: isTaskComposerSendEnabled(
            task: task,
            connected: widget.controller.isConnected,
            sending: _sending,
            attachmentsReady: _attachments.every((file) => file.ready),
          ),
          completions: _completions,
          loadingCompletions: _loadingSkills,
          onCompletion: _selectCompletion,
          onSend: _send,
          sendMode: _sendMode,
          onAttach: Attachments.supported && !_sending && !_pickingAttachment
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
    final draft = _draft;
    final controller = widget.controller;
    final submittedText = _composer.text;
    final text = submittedText.trim();
    if (text.isEmpty && _attachments.isEmpty) return;
    if (_attachments.any((attachment) => !attachment.ready)) {
      _showError(_attachments
              .any((attachment) => attachment.state == AttachmentState.failed)
          ? 'Retry failed attachments before sending.'
          : 'Wait for attachments to finish uploading.');
      return;
    }
    final submittedAttachments = List<AttachmentTransfer>.of(_attachments);
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
      draft.attachments = [];
    });
    _composer.clear();
    try {
      final disposition = await controller.sendPrompt(
        text,
        mode: _sendMode,
        skill: submittedSkill,
        model: settings.model,
        effort: settings.effort,
        serviceTier: settings.serviceTier,
        attachments: submittedAttachments.map((file) => file.remote!).toList(),
      );
      await Attachments.releaseAll(
          submittedAttachments.map((file) => file.local));
      if (!mounted || !identical(_draft, draft)) return;
      if (disposition == TaskMessageDisposition.queued) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message queued for the next turn.')),
        );
      }
    } catch (exception) {
      await draft.restoreFailedSubmission(
        text: submittedText,
        files: submittedAttachments,
        submittedSkill: submittedSkill,
      );
      if (mounted && identical(_draft, draft)) _showError(exception);
    } finally {
      draft.sending = false;
      draft.changed();
    }
  }

  Future<void> _answerTaskQuestions(
    TaskItem item,
    List<String> answers,
  ) async {
    if (_answeredQuestionItemIds.contains(item.id)) return;
    final taskId = widget.task.id;
    final message = formatTaskQuestionAnswers(item.questions, answers);
    final settings = resolveTurnSettings(
      widget.controller.models,
      _turnSettings,
      model: widget.task.model,
      effort: widget.task.reasoningEffort,
      useCatalogDefault: false,
    );
    try {
      await widget.controller.sendPrompt(
        message,
        mode: TaskSendMode.auto,
        model: settings.model,
        effort: settings.effort,
      );
      if (!mounted || widget.task.id != taskId) return;
      setState(() {
        _answeredQuestionItemIds.add(item.id);
        _timelineCache.clear();
      });
    } catch (error) {
      if (mounted && widget.task.id == taskId) _showError(error);
      rethrow;
    }
  }

  Future<void> _pickAttachment(bool image) async {
    final draft = _draft;
    if (draft.attachments.length >= Attachments.maxCount) {
      _showError('Up to 4 attachments per message.');
      return;
    }
    draft.picking = true;
    draft.changed();
    LocalAttachment? picked;
    try {
      picked = await Attachments.pick(image: image);
      if (picked == null) return;
      draft.addAttachment(picked);
      picked = null;
      if (mounted && identical(_draft, draft)) _composerFocus.requestFocus();
    } catch (error) {
      if (picked != null) await Attachments.release(picked);
      if (mounted && identical(_draft, draft)) _showError(error);
    } finally {
      draft.picking = false;
      draft.changed();
    }
  }

  Widget _attachmentChip(AttachmentTransfer attachment) => AnimatedBuilder(
        animation: attachment,
        builder: (context, _) => _buildAttachmentChip(attachment),
      );

  Widget _buildAttachmentChip(AttachmentTransfer attachment) {
    final uploading = attachment.state == AttachmentState.uploading;
    final failed = attachment.state == AttachmentState.failed;
    final waiting = attachment.state == AttachmentState.waiting;
    final theme = Theme.of(context);
    final avatar = attachment.local.isImage
        ? Image.file(File(attachment.local.path),
            width: 32,
            height: 32,
            cacheWidth: 64,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const Icon(Icons.broken_image))
        : Icon(attachment.local.isVideo
            ? Icons.videocam_outlined
            : Icons.insert_drive_file_outlined);
    final message = waiting
        ? 'Waiting for connection'
        : failed
            ? 'Upload failed. Tap to resume.'
            : uploading
                ? 'Uploading ${(attachment.progress * 100).toStringAsFixed(0)}%'
                : 'Uploaded';
    return Tooltip(
      message: message,
      child: Material(
        elevation: uploading ? 7 : 0,
        shadowColor: theme.colorScheme.primary.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(24),
        child: InputChip(
          avatar: SizedBox.square(
            dimension: 32,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipOval(
                    child:
                        Opacity(opacity: uploading ? 0.7 : 1, child: avatar)),
                if (uploading)
                  CustomPaint(
                    painter: _SectorProgressPainter(
                      attachment.progress,
                      theme.colorScheme.primary.withValues(alpha: 0.5),
                    ),
                  ),
                if (failed)
                  DecoratedBox(
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.colorScheme.error.withValues(alpha: 0.82)),
                    child: Icon(Icons.refresh,
                        size: 19, color: theme.colorScheme.onError),
                  ),
                if (attachment.ready)
                  Align(
                    alignment: Alignment.bottomRight,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: theme.colorScheme.primary),
                      child: Icon(Icons.check,
                          size: 13, color: theme.colorScheme.onPrimary),
                    ),
                  ),
              ],
            ),
          ),
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
                waiting
                    ? '${attachment.local.name} · Waiting for connection'
                    : attachment.local.name,
                overflow: TextOverflow.ellipsis),
          ),
          onPressed: failed
              ? () => _retryAttachment(attachment)
              : attachment.local.isImage
                  ? () => _previewAttachment(attachment.local)
                  : attachment.local.isVideo
                      ? () => _previewVideo(attachment.local)
                      : null,
          onDeleted: () => _discardAttachment(attachment),
          deleteButtonTooltipMessage: 'Remove attachment',
        ),
      ),
    );
  }

  void _retryAttachment(AttachmentTransfer attachment) {
    unawaited(_draft.upload(attachment));
  }

  Future<void> _previewVideo(LocalAttachment attachment) async {
    try {
      await Attachments.channel.invokeMethod<bool>('playVideo', {
        'path': attachment.path,
        'name': attachment.name,
      });
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  void _discardAttachment(AttachmentTransfer attachment) {
    _draft.removeAttachment(attachment);
  }

  Future<void> _previewAttachment(LocalAttachment attachment) async {
    await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                    child: InteractiveViewer(
                        child: Image.file(File(attachment.path),
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

  Future<void> _retryQueuedMessage(String messageId) async {
    final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Send this message again?'),
              content: const Text(
                  'Check the latest conversation first. If the server already '
                  'received this message, sending it again may execute it twice.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Send again')),
              ],
            ));
    if (confirm == true && mounted) {
      await _runQueueAction(() =>
          widget.controller.retryQueuedMessage(widget.task.id, messageId));
    }
  }

  Future<void> _turnAction(TaskItem item) async {
    if (!widget.controller.isConnected || item.turnId == null || _commandBusy) {
      return;
    }
    final action = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                  leading: const Icon(Icons.fork_right),
                  title: const Text('Fork through this turn'),
                  onTap: () => Navigator.pop(context, 'fork')),
              ListTile(
                  leading: const Icon(Icons.undo),
                  title: const Text('Revert from this turn'),
                  onTap: () => Navigator.pop(context, 'revert')),
            ])));
    if (!mounted || action == null) return;
    if (action == 'fork') {
      await _runCommand(
          () => widget.controller.forkSelectedTask(turnId: item.turnId));
      return;
    }
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Revert conversation?'),
              content: const Text(
                  'Remove this turn and all later turns from conversation history. '
                  'Files are NOT reverted. Fork first if you want to keep a copy.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Revert')),
              ],
            ));
    if (confirmed == true && mounted) {
      await _runCommand(
          () => widget.controller.revertSelectedTask(item.turnId!));
    }
  }

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
      case TaskCommand.rename:
        final name = await askTaskName(context, widget.task.title);
        if (name != null && mounted) {
          await _runCommand(
              () => widget.controller.renameTask(widget.task.id, name));
        }
      case TaskCommand.pin:
        await _runCommand(() =>
            widget.controller.pinTask(widget.task.id, !widget.task.isPinned));
      case TaskCommand.archive:
        if (await confirmArchive(context) && mounted) {
          await _runCommand(
              () => widget.controller.archiveTask(widget.task.id, true));
        }
      case TaskCommand.fork:
        await _runCommand(() => widget.controller.forkSelectedTask());
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
    if (widget.controller.isConnected &&
        _availableSkills == null &&
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

enum TaskCommand {
  skills,
  goal,
  compact,
  interrupt,
  rename,
  pin,
  archive,
  fork
}

class QueuedMessagePanel extends StatelessWidget {
  const QueuedMessagePanel({
    required this.messages,
    required this.enabled,
    required this.onSteer,
    required this.onRemove,
    this.deliveryState,
    this.onRetry,
    super.key,
  });

  final List<QueuedTaskMessage> messages;
  final bool enabled;
  final Future<void> Function(String messageId) onSteer;
  final Future<void> Function(String messageId) onRemove;
  final String? Function(String id)? deliveryState;
  final Future<void> Function(String id)? onRetry;

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
                    final state = deliveryState?.call(message.id);
                    final needsReview =
                        state == 'uncertain' || state == 'failed';
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
                                if (needsReview)
                                  Text(
                                      state == 'uncertain'
                                          ? 'Delivery unknown · Check conversation before retrying'
                                          : 'Not sent · Retry or remove',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall),
                              ],
                            ),
                          ),
                        ),
                        Tooltip(
                          message: 'Steer queued message',
                          child: TextButton.icon(
                            onPressed: enabled
                                ? () async => needsReview
                                    ? onRetry?.call(message.id)
                                    : onSteer(message.id)
                                : null,
                            icon: const Icon(Icons.redo, size: 18),
                            label: Text(needsReview ? 'Retry' : 'Steer'),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Remove queued message',
                          onPressed: () async => onRemove(message.id),
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
          PopupMenuItem(value: TaskCommand.rename, child: Text('Rename')),
          PopupMenuItem(value: TaskCommand.pin, child: Text('Pin / unpin')),
          PopupMenuItem(value: TaskCommand.archive, child: Text('Archive')),
          PopupMenuItem(
              value: TaskCommand.fork, child: Text('Fork conversation')),
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
    this.answeredQuestionItemIds = const {},
    this.onAnswerQuestions,
    this.onTurnAction,
    super.key,
  });

  final List<TaskItem> items;
  final Future<void> Function(TaskItem)? onTurnAction;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;
  final bool hasOlder;
  final bool loadingOlder;
  final String? olderError;
  final Future<void> Function()? onLoadOlder;
  final Future<Uint8List> Function(String)? loadImage;
  final Set<String> answeredQuestionItemIds;
  final Future<void> Function(TaskItem item, List<String> answers)?
      onAnswerQuestions;

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
    if (widget.loading && widget.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (widget.error != null && widget.items.isEmpty) {
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
    final openQuestionItemId = latestOpenTaskQuestionItemId(
      widget.items,
      widget.answeredQuestionItemIds,
    );
    final timeline = Stack(
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
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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
                    TimelineMessageEntry(:final item) => GestureDetector(
                        onLongPress:
                            item.turnId != null && widget.onTurnAction != null
                                ? () => widget.onTurnAction!(item)
                                : null,
                        child: TimelineItemView(
                          item: item,
                          loadImage: widget.loadImage,
                          onTurnAction: item.kind == TaskItemKind.user &&
                                  item.turnId != null &&
                                  widget.onTurnAction != null
                              ? () => widget.onTurnAction!(item)
                              : null,
                          onAnswerQuestions: item.id == openQuestionItemId &&
                                  widget.onAnswerQuestions != null
                              ? (answers) =>
                                  widget.onAnswerQuestions!(item, answers)
                              : null,
                        )),
                    TimelineActivityEntry(:final items) =>
                      TimelineActivityGroup(
                          items: items, loadImage: widget.loadImage),
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
    return Column(
      children: [
        if (widget.loading) const LinearProgressIndicator(minHeight: 2),
        if (widget.error != null)
          Material(
            key: const Key('task-refresh-error'),
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                      child: Text('Showing cached context. ${widget.error}')),
                  TextButton(
                      onPressed: widget.onRetry, child: const Text('Retry')),
                ],
              ),
            ),
          ),
        Expanded(child: timeline),
      ],
    );
  }
}

String? latestOpenTaskQuestionItemId(
  List<TaskItem> items,
  Set<String> answeredItemIds,
) {
  String? result;
  for (final item in items) {
    if (item.kind == TaskItemKind.user) {
      result = null;
    } else if (item.kind == TaskItemKind.agent &&
        item.questions.isNotEmpty &&
        !answeredItemIds.contains(item.id)) {
      result = item.id;
    }
  }
  return result;
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
    required this.focusNode,
    required this.inputEnabled,
    required this.sendEnabled,
    required this.completions,
    required this.loadingCompletions,
    required this.onCompletion,
    required this.onSend,
    required this.sendMode,
    this.onAttach,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool inputEnabled;
  final bool sendEnabled;
  final List<ComposerCompletion> completions;
  final bool loadingCompletions;
  final ValueChanged<ComposerCompletion> onCompletion;
  final VoidCallback onSend;
  final TaskSendMode sendMode;
  final ValueChanged<bool>? onAttach;

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
                        PopupMenuItem(
                            value: false, child: Text('File or video')),
                      ],
                    ),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      enabled: inputEnabled,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Message Codex',
                        isDense: true,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
  const SendModePicker(
      {required this.value,
      required this.enabled,
      required this.onChanged,
      this.compact = false,
      super.key});
  final bool compact;
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
          PopupMenuItem(
              value: TaskSendMode.auto, child: Text('Auto — start or steer')),
          PopupMenuItem(
              value: TaskSendMode.steer,
              child: Text('Steer — guide the current turn')),
          PopupMenuItem(
              value: TaskSendMode.queue, child: Text('Queue — send when idle')),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(switch (value) {
              TaskSendMode.auto => 'Auto',
              TaskSendMode.steer => compact ? 'Steer' : 'Steer current turn',
              TaskSendMode.queue => compact ? 'Queue' : 'Queue for next turn',
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
