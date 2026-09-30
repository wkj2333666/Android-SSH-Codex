import 'package:android_ssh_codex/src/protocol/codex_remote_api.dart';
import 'package:android_ssh_codex/src/ui/turn_settings_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const models = [
    RemoteModel(
      id: 'sol-entry',
      model: 'gpt-5.6-sol',
      displayName: 'GPT-5.6 Sol',
      description: 'Frontier coding model',
      isDefault: true,
      defaultReasoningEffort: 'high',
      supportedReasoningEfforts: [
        RemoteReasoningEffort(
          effort: 'medium',
          description: 'Fast and capable',
        ),
        RemoteReasoningEffort(
          effort: 'high',
          description: 'Deeper reasoning',
        ),
      ],
    ),
    RemoteModel(
      id: 'terra-entry',
      model: 'gpt-5.6-terra',
      displayName: 'GPT-5.6 Terra',
      description: 'Balanced coding model',
      isDefault: false,
      defaultReasoningEffort: 'medium',
      supportedReasoningEfforts: [
        RemoteReasoningEffort(
          effort: 'medium',
          description: 'Balanced reasoning',
        ),
      ],
    ),
  ];

  testWidgets('selecting a model selects its advertised default effort',
      (tester) async {
    var selection = const TurnSettings();
    late StateSetter updateHost;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            updateHost = setState;
            return TurnSettingsPicker(
              models: models,
              value: selection,
              onChanged: (value) => updateHost(() => selection = value),
            );
          },
        ),
      ),
    ));

    expect(find.text('GPT-5.6 Sol · high'), findsOneWidget);
    expect(find.text('Server default'), findsNothing);
    await tester.tap(find.byKey(const Key('turn-settings-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GPT-5.6 Sol').last);
    await tester.pumpAndSettle();

    expect(selection.model, isNull);
    await tester.tap(find.byKey(const Key('turn-settings-apply')));
    await tester.pumpAndSettle();

    expect(selection.model, 'gpt-5.6-sol');
    expect(selection.effort, 'high');
    expect(find.text('GPT-5.6 Sol · high'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
  });

  testWidgets('effort menu contains only values advertised by the model',
      (tester) async {
    var selection = const TurnSettings(
      model: 'gpt-5.6-sol',
      effort: 'high',
    );
    late StateSetter updateHost;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            updateHost = setState;
            return TurnSettingsPicker(
              models: models,
              value: selection,
              onChanged: (value) => updateHost(() => selection = value),
            );
          },
        ),
      ),
    ));

    await tester.tap(find.byKey(const Key('turn-settings-selector')));
    await tester.pumpAndSettle();

    expect(find.text('medium'), findsOneWidget);
    expect(find.text('high'), findsWidgets);
    expect(find.text('xhigh'), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('turn-effort-medium')));
    await tester.tap(find.byKey(const Key('turn-effort-medium')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('turn-settings-apply')));
    await tester.pumpAndSettle();

    expect(selection.effort, 'medium');
  });

  testWidgets('switching models resets effort; dismissal discards draft',
      (tester) async {
    var changes = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TurnSettingsPicker(
        models: models,
        value: const TurnSettings(model: 'gpt-5.6-sol', effort: 'high'),
        onChanged: (_) => changes++,
      )),
    ));
    await tester.tap(find.byKey(const Key('turn-settings-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('turn-model-gpt-5.6-terra')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('turn-effort-high')), findsNothing);
    expect(tester.widget<ChoiceChip>(find.byKey(const Key('turn-effort-medium'))).selected, true);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(changes, 0);
    expect(find.text('GPT-5.6 Sol · high'), findsOneWidget);
  });

  testWidgets('implicit values are resolved to concrete settings', (tester) async {
    TurnSettings? selection;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TurnSettingsPicker(
        models: models,
        value: const TurnSettings(),
        onChanged: (value) => selection = value,
      )),
    ));
    await tester.tap(find.byKey(const Key('turn-settings-selector')));
    await tester.pumpAndSettle();
    expect(find.text('Server default'), findsNothing);
    expect(find.text('Default'), findsNothing);
    await tester.tap(find.byKey(const Key('turn-settings-apply')));
    await tester.pumpAndSettle();
    expect(selection, isNotNull);
    expect(selection!.model, 'gpt-5.6-sol');
    expect(selection!.effort, 'high');
  });

  test('task settings take priority over the catalog default', () {
    final actual = resolveTurnSettings(models, const TurnSettings(),
        model: 'gpt-5.6-terra', effort: 'medium');
    expect(actual.model, 'gpt-5.6-terra');
    expect(actual.effort, 'medium');
    final override = resolveTurnSettings(models,
        const TurnSettings(model: 'gpt-5.6-sol', effort: 'high'),
        model: 'gpt-5.6-terra', effort: 'medium');
    expect(override.model, 'gpt-5.6-sol');
    expect(override.effort, 'high');
    final unknown = resolveTurnSettings(const [], const TurnSettings(),
        model: 'custom', effort: 'custom-effort');
    expect(unknown.model, 'custom');
    expect(unknown.effort, 'custom-effort');
    expect(resolveTurnSettings(const [], const TurnSettings()).model, isNull);
  });

  testWidgets('disabled selector stays closed with an unavailable model',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TurnSettingsPicker(
        models: const [],
        value: const TurnSettings(model: 'custom-model', effort: 'high'),
        enabled: false,
        onChanged: (_) => fail('disabled picker changed settings'),
      )),
    ));
    expect(find.text('custom-model · high'), findsOneWidget);
    await tester.tap(find.byKey(const Key('turn-settings-selector')));
    await tester.pumpAndSettle();
    expect(find.text('Model and reasoning effort'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('combined panel scrolls on a small screen', (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TurnSettingsPicker(
        models: models,
        value: const TurnSettings(model: 'gpt-5.6-sol', effort: 'high'),
        onChanged: (_) {},
      )),
    ));
    await tester.tap(find.byKey(const Key('turn-settings-selector')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('turn-effort-medium')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('turn-effort-medium')));
    await tester.tap(find.byKey(const Key('turn-settings-apply')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
