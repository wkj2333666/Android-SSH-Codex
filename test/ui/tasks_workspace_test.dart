import 'dart:async';

import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/projects/remote_project.dart';
import 'package:android_ssh_codex/src/tasks/task_reducer.dart';
import 'package:android_ssh_codex/src/ui/task_view.dart';
import 'package:android_ssh_codex/src/ui/tasks_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TaskRecord task(String id, String title, String cwd) => TaskRecord(
        id: id,
        title: title,
        status: TaskStatus.completed,
        cwd: cwd,
        updatedAt: DateTime.utc(2026, 8, 1),
        items: const [],
        ownership: TaskOwnership.available,
        revision: 0,
      );

  const project = RemoteProject(
    id: 'mobile',
    hostId: 'pi',
    name: 'Mobile',
    cwd: '/srv/mobile',
  );

  testWidgets('projects lead the list and unassigned tasks start collapsed',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TaskListPane(
          model: TaskListPaneModel(
            projects: const [project],
            selectedProjectId: project.id,
            projectTasks: [task('project', 'Project task', project.cwd)],
            unassignedTasks: [task('loose', 'Loose task', '/tmp/scratch')],
            connected: true,
          ),
        ),
      ),
    ));

    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('Mobile'), findsWidgets);
    expect(find.text('Project task'), findsOneWidget);
    expect(find.text('Unassigned'), findsOneWidget);
    expect(find.text('Loose task'), findsNothing);

    await tester.tap(find.text('Unassigned'));
    await tester.pumpAndSettle();

    expect(find.text('Loose task'), findsOneWidget);
  });

  testWidgets('project paging invokes the explicit load-more callback',
      (tester) async {
    var invoked = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TaskListPane(
          model: TaskListPaneModel(
            projects: const [project],
            selectedProjectId: project.id,
            projectTasks: [task('project', 'Project task', project.cwd)],
            unassignedTasks: const [],
            connected: true,
            hasMoreProjectTasks: true,
          ),
          onLoadMoreProjectTasks: () => invoked = true,
        ),
      ),
    ));

    await tester.tap(find.byKey(const Key('load-more-project')));

    expect(invoked, isTrue);
  });

  testWidgets('project loading is not presented as an empty project',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TaskListPane(
          model: TaskListPaneModel(
            projects: const [project],
            selectedProjectId: project.id,
            projectTasks: [],
            unassignedTasks: [],
            connected: true,
            loadingProjectPage: true,
          ),
        ),
      ),
    ));

    expect(find.text('No tasks in this project'), findsNothing);
    expect(find.byKey(const Key('project-head-progress')), findsOneWidget);
  });

  testWidgets('tasks mode shows all recent tasks without project chrome',
      (tester) async {
    TaskListMode? selectedMode;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TaskListPane(
          model: TaskListPaneModel(
            projects: const [project],
            selectedProjectId: project.id,
            projectTasks: [task('project', 'Project task', project.cwd)],
            recentTasks: [task('recent', 'Recent task', '/srv/other')],
            unassignedTasks: const [],
            connected: true,
            initialMode: TaskListMode.tasks,
          ),
          onModeChanged: (mode) => selectedMode = mode,
        ),
      ),
    ));

    expect(find.text('Recent tasks'), findsOneWidget);
    expect(find.text('Recent task'), findsOneWidget);
    expect(find.text('Project task'), findsNothing);
    expect(find.text('Unassigned'), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);

    await tester.tap(find.text('Projects'));
    await tester.pump();

    expect(selectedMode, TaskListMode.projects);
  });

  testWidgets('task timeline distinguishes loading, failure, and empty history',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TaskTimeline(items: [], loading: true),
      ),
    ));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('No task events yet'), findsNothing);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TaskTimeline(
          items: const [],
          error: 'Could not read task',
          onRetry: () {},
        ),
      ),
    ));
    expect(find.text('Could not read task'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TaskTimeline(items: []),
      ),
    ));
    expect(find.text('No task events yet'), findsOneWidget);
  });

  testWidgets('task timeline follows latest content and exposes jump control',
      (tester) async {
    tester.view.physicalSize = const Size(360, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final items = List.generate(
      40,
      (index) => TaskItem(
        id: 'message-$index',
        kind: TaskItemKind.agent,
        text: 'Model response $index\n\nSecond line for scrolling.',
      ),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TaskTimeline(items: items)),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Model response 39'), findsOneWidget);
    expect(find.textContaining('Model response 0'), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, 900));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('jump-to-latest')), findsOneWidget);

    await tester.tap(find.byKey(const Key('jump-to-latest')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Model response 39'), findsOneWidget);
    expect(find.byKey(const Key('jump-to-latest')), findsNothing);
  });

  testWidgets('loaded long timeline opens at the latest item', (tester) async {
    tester.view.physicalSize = const Size(360, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late StateSetter updateHost;
    var loading = true;
    var items = const <TaskItem>[];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            updateHost = setState;
            return TaskTimeline(items: items, loading: loading);
          },
        ),
      ),
    ));

    updateHost(() {
      loading = false;
      items = longTimelineItems();
    });
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Long response 999').hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets('one jump action reaches the end of a long timeline',
      (tester) async {
    tester.view.physicalSize = const Size(360, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TaskTimeline(items: longTimelineItems())),
    ));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, 1800));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('jump-to-latest')), findsOneWidget);

    await tester.tap(find.byKey(const Key('jump-to-latest')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Long response 999').hitTestable(),
      findsOneWidget,
    );
    expect(find.byKey(const Key('jump-to-latest')), findsNothing);
  });

  testWidgets('scrolling to the top requests one older context page',
      (tester) async {
    tester.view.physicalSize = const Size(360, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pending = Completer<void>();
    var requests = 0;
    final items = List.generate(
      30,
      (index) => TaskItem(
        id: 'message-$index',
        kind: TaskItemKind.agent,
        text: 'Current message $index\n\nScrollable detail.',
      ),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TaskTimeline(
          items: items,
          hasOlder: true,
          onLoadOlder: () async {
            requests++;
            await pending.future;
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, 4000));
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, 1000));
    await tester.pump();

    expect(requests, 1);
    expect(find.byKey(const Key('older-context-progress')), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, 500));
    await tester.pump();
    expect(requests, 1);
    pending.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('prepending older context preserves the visible anchor',
      (tester) async {
    tester.view.physicalSize = const Size(360, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pending = Completer<void>();
    late StateSetter updateHost;
    var items = List.generate(
      30,
      (index) => TaskItem(
        id: 'message-$index',
        kind: TaskItemKind.agent,
        text: 'Anchor message $index\n\nScrollable detail.',
      ),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            updateHost = setState;
            return TaskTimeline(
              items: items,
              hasOlder: true,
              onLoadOlder: () => pending.future,
            );
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 4000));
    await tester.pump();

    final anchor = find.textContaining('Anchor message 0');
    expect(anchor, findsOneWidget);
    final before = tester.getTopLeft(anchor).dy;

    updateHost(() {
      items = [
        for (var index = 10; index > 0; index--)
          TaskItem(
            id: 'older-$index',
            kind: TaskItemKind.user,
            text: 'Older message $index\n\nScrollable detail.',
          ),
        ...items,
      ];
    });
    pending.complete();
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(anchor).dy, closeTo(before, 1));
  });

  testWidgets('viewport shrink keeps a followed timeline at the latest item',
      (tester) async {
    tester.view.physicalSize = const Size(360, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final items = List.generate(
      40,
      (index) => TaskItem(
        id: 'metric-message-$index',
        kind: TaskItemKind.agent,
        text: 'Viewport response $index\n\nSecond line for scrolling.',
      ),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TaskTimeline(items: items)),
    ));
    await tester.pumpAndSettle();
    final latest = find.textContaining('Viewport response 39');
    expect(latest.hitTestable(), findsOneWidget);

    tester.view.physicalSize = const Size(360, 360);
    await tester.pumpAndSettle();

    expect(latest.hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('jump-to-latest')), findsNothing);
  });

  testWidgets('task command menu exposes stable commands only', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TaskCommandMenu(
          enabled: true,
          onSelected: (_) {},
        ),
      ),
    ));

    await tester.tap(find.byTooltip('Task commands'));
    await tester.pumpAndSettle();

    expect(find.text('Skills'), findsOneWidget);
    expect(find.text('Goal'), findsOneWidget);
    expect(find.text('Compact context'), findsOneWidget);
    expect(find.textContaining('Experimental'), findsNothing);
  });

  testWidgets('switching tasks clears the previous composer draft',
      (tester) async {
    final controller = AppController.memory();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TaskView(
          controller: controller,
          task: task('first', 'First task', '/srv/mobile'),
        ),
      ),
    ));
    tester.widget<TextField>(find.byType(TextField)).controller!.text =
        'draft for first task';

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TaskView(
          controller: controller,
          task: task('second', 'Second task', '/srv/mobile'),
        ),
      ),
    ));

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('system back leaves a mobile task before exiting the app',
      (tester) async {
    tester.view.physicalSize = const Size(360, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController.memory();
    addTearDown(controller.dispose);
    var controllerNotified = false;
    controller.addListener(() => controllerNotified = true);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TaskView(
          controller: controller,
          task: task('mobile', 'Mobile task', '/srv/mobile'),
        ),
      ),
    ));

    final handled = await tester.binding.handlePopRoute();
    await tester.pump();

    expect(handled, isTrue);
    expect(controllerNotified, isTrue);
    expect(find.byType(TaskView), findsOneWidget);
  });

  test('an external running task still accepts composer input', () {
    final external = TaskRecord(
      id: 'external',
      title: 'External task',
      status: TaskStatus.running,
      cwd: '/srv/mobile',
      updatedAt: DateTime.utc(2026, 8, 2),
      items: const [],
      ownership: TaskOwnership.external,
      revision: 1,
    );

    expect(
      isTaskComposerEnabled(
        task: external,
        connected: true,
        sending: false,
      ),
      isTrue,
    );
  });

  test('sending locks submission without locking composer input', () {
    final available = task('available', 'Available task', '/srv/mobile');

    expect(
      isTaskComposerInputEnabled(task: available, connected: true),
      isTrue,
    );
    expect(
      isTaskComposerSendEnabled(
        task: available,
        connected: true,
        sending: true,
      ),
      isFalse,
    );
  });

  test('a failed send restores its draft only when no new draft was typed', () {
    expect(
      restoreComposerDraft(
        currentText: '',
        submittedText: 'original message',
      ),
      'original message',
    );
    expect(
      restoreComposerDraft(
        currentText: 'next message',
        submittedText: 'original message',
      ),
      'next message',
    );
  });

  testWidgets('queued messages remain visible with steer and remove actions',
      (tester) async {
    String? steeredId;
    String? removedId;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: QueuedMessagePanel(
          messages: const [
            QueuedTaskMessage(
              id: 'queued-1',
              text: 'Use the latest logs before continuing',
              model: 'gpt-5',
              effort: 'high',
            ),
          ],
          enabled: true,
          onSteer: (id) async => steeredId = id,
          onRemove: (id) async => removedId = id,
        ),
      ),
    ));

    expect(find.text('Queued messages (1)'), findsOneWidget);
    expect(find.text('Use the latest logs before continuing'), findsOneWidget);

    await tester.tap(find.byTooltip('Steer queued message'));
    await tester.pump();
    expect(steeredId, 'queued-1');

    await tester.tap(find.byTooltip('Remove queued message'));
    await tester.pump();
    expect(removedId, 'queued-1');
  });
}

List<TaskItem> longTimelineItems() {
  return List.generate(
    1000,
    (index) => TaskItem(
      id: 'long-message-$index',
      kind: TaskItemKind.agent,
      text: index < 900 || index == 999
          ? 'Long response $index'
          : 'Long response $index\n\n${List.filled(20, 'detail').join('\n\n')}',
    ),
  );
}
