import 'package:android_ssh_codex/src/ui/permission_picker.dart';
import 'package:android_ssh_codex/src/tasks/permission_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/tasks/task_reducer.dart';
import 'package:android_ssh_codex/src/ui/task_view.dart';

void main() {
  testWidgets(
      'sending permissions slash command opens local picker, not outbox',
      (tester) async {
    final controller = AppController.memory(cachedTasks: [
      TaskSnapshot(
          id: 'task',
          title: 'Task',
          cwd: '/work',
          status: TaskStatus.completed,
          updatedAt: DateTime.utc(2026),
          items: const [])
    ]);
    await controller.selectTask('task');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: TaskView(
                controller: controller, task: controller.selectedTask!))));
    controller.draftForTask('task').composer.text = '/permissions';
    await tester.pump();
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(find.text('Permissions · next new turn'), findsOneWidget);
    expect(controller.queuedMessagesForTask('task'), isEmpty);
    await tester.tap(find.byKey(const ValueKey('permission-readOnly')));
    await tester.pumpAndSettle();
    expect(controller.draftForTask('task').permissionMode,
        PermissionMode.readOnly);
    expect(controller.draftForTask('task').composer.text, isEmpty);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('full access requires confirmation and cancel preserves intent',
      (tester) async {
    PermissionMode? chosen;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PermissionPicker(
                value: PermissionMode.inherit,
                onChanged: (value) => chosen = value))));
    await tester.tap(find.byKey(const Key('permission-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('permission-fullAccess')));
    await tester.pumpAndSettle();
    expect(find.text('Allow full access?'), findsOneWidget);
    expect(chosen, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(chosen, isNull);
    await tester.tap(find.byKey(const Key('permission-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('permission-workspace')));
    await tester.pumpAndSettle();
    expect(chosen, PermissionMode.workspace);
  });
}
