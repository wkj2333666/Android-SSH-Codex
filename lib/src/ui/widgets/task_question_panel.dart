import 'dart:async';

import 'package:flutter/material.dart';

import '../../tasks/task_reducer.dart';

typedef TaskQuestionSubmitter = Future<void> Function(List<String> answers);

String formatTaskQuestionAnswers(
  List<TaskQuestion> questions,
  List<String> answers,
) {
  if (questions.length != answers.length || answers.isEmpty) {
    throw ArgumentError('Every question needs an answer.');
  }
  final normalized = answers.map((answer) => answer.trim()).toList();
  if (normalized.any((answer) => answer.isEmpty)) {
    throw ArgumentError('Every question needs an answer.');
  }
  if (normalized.length == 1) return normalized.single;
  return [
    for (var index = 0; index < normalized.length; index++)
      '${index + 1}. ${questions[index].title}\n${normalized[index]}',
  ].join('\n\n');
}

class TaskQuestionPanel extends StatefulWidget {
  const TaskQuestionPanel({
    required this.questions,
    required this.onSubmit,
    super.key,
  });

  final List<TaskQuestion> questions;
  final TaskQuestionSubmitter? onSubmit;

  @override
  State<TaskQuestionPanel> createState() => _TaskQuestionPanelState();
}

class _TaskQuestionPanelState extends State<TaskQuestionPanel> {
  late List<TextEditingController> _answers;
  var _submitting = false;

  @override
  void initState() {
    super.initState();
    _answers = _newControllers();
  }

  @override
  void didUpdateWidget(covariant TaskQuestionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.questions.length == widget.questions.length) return;
    for (final controller in _answers) {
      controller.dispose();
    }
    _answers = _newControllers();
  }

  List<TextEditingController> _newControllers() => [
        for (var index = 0; index < widget.questions.length; index++)
          TextEditingController(),
      ];

  @override
  void dispose() {
    for (final controller in _answers) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _complete =>
      _answers.every((controller) => controller.text.trim().isNotEmpty);

  Future<void> _submit() async {
    final submit = widget.onSubmit;
    if (submit == null || _submitting || !_complete) return;
    setState(() => _submitting = true);
    try {
      await submit([for (final controller in _answers) controller.text]);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send answers. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onSubmit != null && !_submitting;
    return SelectionContainer.disabled(
      child: Card(
        key: const Key('task-question-panel'),
        margin: const EdgeInsets.only(top: 10),
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.onSubmit == null ? 'Answered' : 'Your response',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              for (var index = 0;
                  index < widget.questions.length;
                  index++) ...[
                Text(widget.questions[index].title),
                if (widget.questions[index].options.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final option in widget.questions[index].options)
                        ChoiceChip(
                          label: Text(option),
                          selected: _answers[index].text == option,
                          onSelected: enabled
                              ? (selected) {
                                  if (!selected) return;
                                  setState(() =>
                                      _answers[index].text = option);
                                }
                              : null,
                        ),
                    ],
                  ),
                ],
                if (widget.onSubmit != null) ...[
                  const SizedBox(height: 6),
                  TextField(
                    key: ValueKey('task-question-answer-$index'),
                    controller: _answers[index],
                    enabled: enabled,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Answer',
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ],
                if (index != widget.questions.length - 1)
                  const SizedBox(height: 14),
              ],
              if (widget.onSubmit != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: enabled && _complete ? _submit : null,
                    icon: _submitting
                        ? const SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send, size: 17),
                    label: const Text('Submit answers'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
