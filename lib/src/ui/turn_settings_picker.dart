import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../protocol/codex_remote_api.dart';
import '../account_usage.dart';
import 'widgets/account_usage_panel.dart';

import '../tasks/turn_settings.dart';

export '../tasks/turn_settings.dart';

class TurnSettingsPicker extends StatelessWidget {
  const TurnSettingsPicker({
    required this.models,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.useCatalogDefault = true,
    this.accountUsage,
    super.key,
  });

  final List<RemoteModel> models;
  final TurnSettings value;
  final ValueChanged<TurnSettings> onChanged;
  final bool enabled;
  final bool useCatalogDefault;
  final AccountUsageController? accountUsage;

  @override
  Widget build(BuildContext context) {
    final settings = resolveTurnSettings(models, value,
        useCatalogDefault: useCatalogDefault);
    final model = _selectedModel(models, settings);
    final label = settings.model == null
        ? 'Model unavailable'
        : '${model?.displayName ?? settings.model} · '
            '${settings.effort ?? 'Effort unavailable'}'
            '${settings.fast ? ' · Fast' : ''}';
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton(
        key: const Key('turn-settings-selector'),
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
        onPressed: enabled && (models.isNotEmpty || accountUsage != null)
            ? () async {
                FocusScope.of(context).unfocus();
                if (accountUsage != null) unawaited(accountUsage!.refresh());
                final selection = await showModalBottomSheet<TurnSettings>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (_) => _TurnSettingsSheet(
                      models: models, value: settings, accountUsage: accountUsage),
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
  const _TurnSettingsSheet(
      {required this.models, required this.value, this.accountUsage});

  final List<RemoteModel> models;
  final TurnSettings value;
  final AccountUsageController? accountUsage;

  @override
  State<_TurnSettingsSheet> createState() => _TurnSettingsSheetState();
}

class _TurnSettingsSheetState extends State<_TurnSettingsSheet> {
  late TurnSettings _draft = widget.value;

  @override
  Widget build(BuildContext context) {
    final model = _selectedModel(widget.models, _draft);
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: ListView(
                children: [
                  if (widget.accountUsage != null)
                    AccountUsagePanel(controller: widget.accountUsage!),
                  if (model == null && _draft.model != null)
                    ListTile(
                        title: Text(_draft.model!),
                        subtitle: const Text('Current task model'),
                        trailing: const Icon(Icons.check)),
                  for (final candidate in widget.models)
                    ListTile(
                      key: ValueKey('turn-model-${candidate.model}'),
                      title: Text(candidate.displayName),
                      subtitle: candidate.description.isEmpty
                          ? null
                          : Text(candidate.description,
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                      selected: candidate.model == _draft.model,
                      trailing: candidate.model == _draft.model
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => setState(() {
                        if (candidate.model == _draft.model) return;
                        _draft = TurnSettings(
                          model: candidate.model,
                          effort: candidate.defaultReasoningEffort,
                          serviceTier: _draft.fast
                              ? candidate.fastServiceTier ?? 'default'
                              : _draft.serviceTier,
                        );
                      }),
                    ),
                ],
              ),
            ),
            if (model != null) ...[
              const Divider(height: 1),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight:
                      math.min(160, MediaQuery.sizeOf(context).height * 0.2),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile.adaptive(
                        key: const Key('turn-fast-toggle'),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Fast'),
                        subtitle: Text(model.supportsFast
                            ? 'New turns only · Higher usage'
                            : 'Not advertised by this model/server'),
                        value: _draft.fast,
                        onChanged: model.supportsFast
                            ? (enabled) => setState(() {
                                  _draft = TurnSettings(
                                    model: _draft.model,
                                    effort: _draft.effort,
                                    serviceTier: enabled
                                        ? model.fastServiceTier
                                        : 'default',
                                  );
                                })
                            : null,
                      ),
                      const Text('Reasoning effort'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final option in _effortsFor(model))
                            Tooltip(
                              message: option.description,
                              child: ChoiceChip(
                                key: ValueKey('turn-effort-${option.effort}'),
                                label: Text(option.effort),
                                selected: option.effort == _draft.effort,
                                onSelected: (_) => setState(() {
                                  _draft = TurnSettings(
                                      model: model.model,
                                      effort: option.effort,
                                      serviceTier: _draft.serviceTier);
                                }),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                key: const Key('turn-settings-apply'),
                onPressed: _draft.model == null
                    ? null
                    : () => Navigator.pop(context, _draft),
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

List<RemoteReasoningEffort> _effortsFor(RemoteModel model) {
  if (model.supportedReasoningEfforts
      .any((item) => item.effort == model.defaultReasoningEffort)) {
    return model.supportedReasoningEfforts;
  }
  return [
    RemoteReasoningEffort(
        effort: model.defaultReasoningEffort, description: ''),
    ...model.supportedReasoningEfforts,
  ];
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
