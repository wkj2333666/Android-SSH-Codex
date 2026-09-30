import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../protocol/codex_remote_api.dart';

final class TurnSettings {
  const TurnSettings({this.model, this.effort});

  final String? model;
  final String? effort;
}

class TurnSettingsPicker extends StatelessWidget {
  const TurnSettingsPicker({
    required this.models,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });

  final List<RemoteModel> models;
  final TurnSettings value;
  final ValueChanged<TurnSettings> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final model = _selectedModel(models, value);
    final effort = _selectedEffort(model, value);
    final label = value.model == null
        ? 'Server default'
        : '${model?.displayName ?? value.model}'
            '${effort == null ? '' : ' · $effort'}';
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton(
        key: const Key('turn-settings-selector'),
        onPressed: enabled
            ? () async {
                final selection = await showModalBottomSheet<TurnSettings>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (_) => _TurnSettingsSheet(models: models, value: value),
                );
                if (context.mounted && selection != null) onChanged(selection);
              }
            : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.memory_outlined, size: 18),
            const SizedBox(width: 8),
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 18),
          ],
        ),
      ),
    );
  }
}

class _TurnSettingsSheet extends StatefulWidget {
  const _TurnSettingsSheet({required this.models, required this.value});

  final List<RemoteModel> models;
  final TurnSettings value;

  @override
  State<_TurnSettingsSheet> createState() => _TurnSettingsSheetState();
}

class _TurnSettingsSheetState extends State<_TurnSettingsSheet> {
  late TurnSettings _draft = widget.value;

  @override
  Widget build(BuildContext context) {
    final model = _selectedModel(widget.models, _draft);
    final effort = _selectedEffort(model, _draft);
    return SafeArea(
      top: false,
      child: SizedBox(
        height: math.min(560, MediaQuery.sizeOf(context).height * 0.75),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text('Model and reasoning effort',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: ListView(
                children: [
                  ListTile(
                    key: const Key('turn-model-default'),
                    title: const Text('Server default'),
                    subtitle: const Text('Let the server choose model and effort'),
                    selected: _draft.model == null,
                    trailing: _draft.model == null ? const Icon(Icons.check) : null,
                    onTap: () => setState(() => _draft = const TurnSettings()),
                  ),
                  for (final candidate in widget.models)
                    ListTile(
                      key: ValueKey('turn-model-${candidate.model}'),
                      title: Text(candidate.displayName),
                      subtitle: candidate.description.isEmpty
                          ? null
                          : Text(candidate.description, maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                      selected: candidate.model == _draft.model,
                      trailing: candidate.model == _draft.model
                          ? const Icon(Icons.check) : null,
                      onTap: () => setState(() {
                        if (candidate.model == _draft.model) return;
                        _draft = TurnSettings(
                          model: candidate.model,
                          effort: candidate.defaultReasoningEffort,
                        );
                      }),
                    ),
                  if (model != null) ...[
                    const Divider(),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
                      child: Text('Reasoning effort'),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final option in _effortsFor(model))
                            Tooltip(
                              message: option.description,
                              child: ChoiceChip(
                                key: ValueKey('turn-effort-${option.effort}'),
                                label: Text(option.effort),
                                selected: option.effort == effort,
                                onSelected: (_) => setState(() {
                                  _draft = TurnSettings(
                                    model: model.model,
                                    effort: option.effort,
                                  );
                                }),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                key: const Key('turn-settings-apply'),
                onPressed: () => Navigator.pop(context, TurnSettings(
                  model: _draft.model,
                  effort: _draft.model == null ? null : effort,
                )),
                child: const Text('Apply'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

RemoteModel? _selectedModel(List<RemoteModel> models, TurnSettings value) =>
    models.where((candidate) => candidate.model == value.model).firstOrNull;

String? _selectedEffort(RemoteModel? model, TurnSettings value) {
  if (model == null) return value.effort;
  return _effortsFor(model).any((option) => option.effort == value.effort)
      ? value.effort
      : model.defaultReasoningEffort;
}

List<RemoteReasoningEffort> _effortsFor(RemoteModel model) {
  if (model.supportedReasoningEfforts
      .any((item) => item.effort == model.defaultReasoningEffort)) {
    return model.supportedReasoningEfforts;
  }
  return [
    RemoteReasoningEffort(effort: model.defaultReasoningEffort, description: ''),
    ...model.supportedReasoningEfforts,
  ];
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
