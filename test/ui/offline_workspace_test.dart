import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/attachments.dart';
import 'package:android_ssh_codex/src/protocol/codex_remote_api.dart';
import 'package:android_ssh_codex/src/tasks/task_draft.dart';
import 'package:android_ssh_codex/src/tasks/task_reducer.dart';
import 'package:android_ssh_codex/src/ui/task_view.dart';
import 'package:android_ssh_codex/src/ui/tasks_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cachedTask = TaskSnapshot(
    id: 'cached',
    title: 'Cached task',
    status: TaskStatus.completed,
    cwd: '/work',
    updatedAt: DateTime.utc(2026, 10, 16),
    items: const [
      TaskItem(id: 'reply', kind: TaskItemKind.agent, text: 'Cached reply')
    ],
  );
  const model = RemoteModel(
    id: 'model',
    model: 'model',
    displayName: 'Cached model',
    description: '',
    isDefault: true,
    defaultReasoningEffort: 'high',
    supportedReasoningEfforts: [
      RemoteReasoningEffort(effort: 'high', description: '')
    ],
  );

  testWidgets('disconnect retains cached messages and model choices',
      (tester) async {
    final controller =
        AppController.memory(cachedTasks: [cachedTask], cachedModels: [model]);
    await controller.selectTask('cached');
    await controller.disconnect();
    controller.clearSelectedTask();
    var notifications = 0;
    controller.addListener(() => notifications++);
    await controller.selectTask('cached');
    expect(notifications, greaterThan(0));
    expect(controller.selectedTask!.items.single.text, 'Cached reply');
    expect(controller.models, [model]);
    expect(controller.isTaskDetailLoading('cached'), isFalse);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: TaskView(
      controller: controller,
      task: controller.selectedTask!,
    ))));
    expect(find.text('Offline · Showing cached messages'), findsOneWidget);
    await tester.tap(find.byKey(const Key('turn-settings-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('turn-model-model')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('turn-settings-apply')));
    await tester.pumpAndSettle();
    expect(controller.draftForTask('cached').settings.model, 'model');
    final timeline = find.descendant(
        of: find.byType(TaskTimeline), matching: find.byType(ListView));
    expect(tester.widget<ListView>(timeline).padding,
        const EdgeInsets.fromLTRB(16, 12, 16, 12));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('offline cached task list remains navigable', (tester) async {
    String? selected;
    final controller = AppController.memory(cachedTasks: [cachedTask]);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: TaskListPane(
      model: TaskListPaneModel(
        selectedProjectId: null,
        projects: const [],
        projectTasks: const [],
        unassignedTasks: const [],
        recentTasks: controller.recentTasks,
        connected: false,
        initialMode: TaskListMode.tasks,
      ),
      onTaskSelected: (id) => selected = id,
    ))));
    await tester.tap(find.text('Cached task'));
    expect(selected, 'cached');
    await tester.tap(find.text('Projects'));
    await tester.pump();
    expect(find.text('No project selected'), findsWidgets);
  });

  testWidgets('offline attachment picker queues files without starting SSH',
      (tester) async {
    final controller = AppController.memory(cachedTasks: [cachedTask]);
    await controller.selectTask('cached');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            Attachments.channel,
            (MethodCall call) async => {
                  'name': 'offline.txt',
                  'path': '/nonexistent/offline-file',
                  'size': 1,
                  'isImage': false,
                });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(Attachments.channel, null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: TaskView(
      controller: controller,
      task: controller.selectedTask!,
    ))));
    await tester.tap(find.byTooltip('Attach image or file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File or video'));
    await tester.pumpAndSettle();
    final draft = controller.draftForTask('cached');
    expect(draft.attachments.single.state, AttachmentState.waiting);
    expect(draft.attachments.single.active, isFalse);
    await tester.enterText(find.byType(TextField), 'offline draft');
    expect(draft.composer.text, 'offline draft');
    await tester.tap(find.byTooltip('Remove attachment'));
    await tester.pump();
    expect(draft.attachments, isEmpty);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('local video composer chips play offline before upload',
      (tester) async {
    final controller = AppController.memory(cachedTasks: [cachedTask]);
    await controller.selectTask('cached');
    final played = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(Attachments.channel, (MethodCall call) async {
      if (call.method == 'playVideo') {
        played.add((call.arguments as Map)['path'] as String);
        return true;
      }
      return {
        'name': 'clip.mp4',
        'path': '/nonexistent/picked-video.bin',
        'size': 1,
        'isImage': false,
        'mimeType': 'video/mp4',
      };
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(Attachments.channel, null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: TaskView(
      controller: controller,
      task: controller.selectedTask!,
    ))));
    await tester.tap(find.byTooltip('Attach image or file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File or video'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('clip.mp4'));
    await tester.pumpAndSettle();
    expect(played, ['/nonexistent/picked-video.bin']);
    expect(controller.draftForTask('cached').attachments.single.active, isFalse);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
