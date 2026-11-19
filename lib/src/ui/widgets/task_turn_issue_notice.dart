import 'dart:async';

import 'package:flutter/material.dart';

import '../../tasks/task_turn_issue.dart';

class TaskTurnIssueNotice extends StatefulWidget {
  const TaskTurnIssueNotice({
    required this.issue,
    required this.autoShow,
    required this.takePopup,
    super.key,
  });

  final TaskTurnIssue issue;
  final bool autoShow;
  final bool Function() takePopup;

  @override
  State<TaskTurnIssueNotice> createState() => _TaskTurnIssueNoticeState();
}

class _TaskTurnIssueNoticeState extends State<TaskTurnIssueNotice>
    with WidgetsBindingObserver {
  bool _scheduled = false;
  bool _open = false;

  bool get _foreground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) setState(() {});
  }

  void _schedulePopup() {
    if (_scheduled || _open || !_foreground || !widget.autoShow) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted ||
          _open ||
          !_foreground ||
          ModalRoute.of(context)?.isCurrent == false ||
          !widget.autoShow ||
          !widget.takePopup()) {
        return;
      }
      unawaited(_showDetails());
    });
  }

  Future<void> _showDetails() async {
    if (_open) return;
    _open = true;
    final issue = widget.issue;
    try {
      await showDialog<void>(
        context: context,
        requestFocus: false,
        builder: (context) => AlertDialog(
          title: const Text('Codex could not complete this turn'),
          scrollable: true,
          content: SelectableText([
            _issueMessage(issue),
            if (issue.details case final details?) details,
            if (issue.code case final code?) 'Code: $code',
          ].join('\n\n')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _open = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ModalRoute.isCurrentOf(context) != false) _schedulePopup();
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.errorContainer,
      child: InkWell(
        onTap: () {
          widget.takePopup();
          unawaited(_showDetails());
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Icon(Icons.error_outline,
                  size: 16, color: colors.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _issueMessage(widget.issue),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: colors.onErrorContainer),
                ),
              ),
              Icon(Icons.chevron_right,
                  size: 18, color: colors.onErrorContainer),
            ],
          ),
        ),
      ),
    );
  }
}

String _issueMessage(TaskTurnIssue issue) =>
    issue.message ?? 'Codex did not provide a failure reason.';
