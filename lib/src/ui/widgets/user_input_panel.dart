import 'package:flutter/material.dart';

import '../../protocol/user_input_request.dart';

class UserInputPanel extends StatefulWidget {
  const UserInputPanel({required this.request, required this.onAnswer, super.key});

  final UserInputRequest request;
  final void Function(Map<String, String>) onAnswer;

  @override
  State<UserInputPanel> createState() => _UserInputPanelState();
}

class _UserInputPanelState extends State<UserInputPanel> {
  final _selected = <String, String>{};
  final _custom = <String, String>{};
  final _useCustom = <String>{};

  Map<String, String> get answers => {
        for (final q in widget.request.questions)
          q.id: q.options.isEmpty || _useCustom.contains(q.id)
              ? _custom[q.id] ?? ''
              : _selected[q.id] ?? '',
      };

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: ExpansionTile(
          initiallyExpanded: true,
          title: Text(widget.request.isBlocking ? 'Answer to continue' : 'Questions for you'),
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.3),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final q in widget.request.questions) ...[
                      Text(q.header, style: Theme.of(context).textTheme.titleSmall),
                      Text(q.question),
                      for (final option in q.options)
                        ListTile(
                          dense: true,
                          title: Text(option.label),
                          subtitle: option.description.isEmpty ? null : Text(option.description),
                          leading: Icon(!_useCustom.contains(q.id) && _selected[q.id] == option.label
                              ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                          selected: !_useCustom.contains(q.id) && _selected[q.id] == option.label,
                          onTap: () => setState(() {
                            _useCustom.remove(q.id);
                            _selected[q.id] = option.label;
                          }),
                        ),
                      if (q.options.isEmpty || q.isOther)
                        TextField(
                          key: ValueKey('answer-${q.id}'),
                          obscureText: q.isSecret,
                          autocorrect: !q.isSecret,
                          enableSuggestions: !q.isSecret,
                          decoration: const InputDecoration(labelText: 'Your answer'),
                          onChanged: (value) => setState(() {
                            _useCustom.add(q.id);
                            _custom[q.id] = value;
                          }),
                        ),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => widget.onAnswer({}), child: const Text('Skip')),
                FilledButton(
                  onPressed: answers.values.every((value) => value.trim().isNotEmpty)
                      ? () => widget.onAnswer(answers) : null,
                  child: const Text('Submit answers'),
                ),
                const SizedBox(width: 12),
              ],
            ),
          ],
        ),
      );
}
