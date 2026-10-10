import 'package:android_ssh_codex/src/tasks/task_message_queue.dart';
import 'package:android_ssh_codex/src/ui/task_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('delivery selector exposes steer and queue without sending',
      (tester) async {
    TaskSendMode? selected;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SendModePicker(
      value: TaskSendMode.auto,
      enabled: true,
      onChanged: (mode) => selected = mode,
    ))));
    await tester.tap(find.byTooltip('Message delivery mode'));
    await tester.pumpAndSettle();
    expect(find.text('Queue — send when idle'), findsOneWidget);
    await tester.tap(find.text('Steer — guide the current turn'));
    await tester.pumpAndSettle();
    expect(selected, TaskSendMode.steer);
    await tester.tap(find.byTooltip('Message delivery mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Queue — send when idle'));
    await tester.pumpAndSettle();
    expect(selected, TaskSendMode.queue);
  });

  testWidgets('selector is disabled while disconnected or sending',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SendModePicker(
      value: TaskSendMode.steer,
      enabled: false,
      onChanged: (_) => fail('disabled selection'),
    ))));
    await tester.tap(find.text('Steer current turn'));
    await tester.pumpAndSettle();
    expect(find.text('Queue — send when idle'), findsNothing);
  });
}
