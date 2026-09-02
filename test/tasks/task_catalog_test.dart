import 'package:android_ssh_codex/src/projects/remote_project.dart';
import 'package:android_ssh_codex/src/tasks/task_catalog.dart';
import 'package:android_ssh_codex/src/tasks/task_reducer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TaskSnapshot snapshot(String id, String cwd) => TaskSnapshot(
        id: id,
        title: 'Task $id',
        status: TaskStatus.completed,
        cwd: cwd,
        updatedAt: DateTime.utc(2026, 8, 1),
        items: const [],
      );

  test(
    'project pages replace then append in server order without duplicates',
    () {
      final catalog = TaskCatalog();

      catalog.replaceProjectPage(
        [snapshot('one', '/repo'), snapshot('two', '/repo')],
        nextCursor: 'page-2',
      );
      catalog.appendProjectPage(
        [snapshot('two', '/repo'), snapshot('three', '/repo')],
        nextCursor: null,
      );

      expect(catalog.projectTaskIds, ['one', 'two', 'three']);
      expect(catalog.projectNextCursor, isNull);
    },
  );

  test(
    'automatic cwd projects leave only empty-cwd tasks unassigned',
    () {
      final catalog = TaskCatalog();
      final tasks = [
        snapshot('repo-task', '/srv/repo'),
        snapshot('scratch-task', '/tmp/scratch/'),
        snapshot('loose-task', ''),
      ];
      final projects = mergeRemoteProjects(
        hostId: 'pi',
        existing: const [],
        discoveredCwds: tasks.map((task) => task.cwd),
      );

      catalog.replaceUnassignedPage(
        tasks,
        projects: projects,
        nextCursor: 'next',
      );

      expect(catalog.unassignedTaskIds, ['loose-task']);
      expect(catalog.unassignedNextCursor, 'next');
    },
  );

  test('unassigned tasks are collapsed until explicitly expanded', () {
    final catalog = TaskCatalog();

    expect(catalog.unassignedExpanded, isFalse);
    catalog.toggleUnassigned();
    expect(catalog.unassignedExpanded, isTrue);
  });

  test('refreshing the project head keeps explicitly loaded older tasks', () {
    final catalog = TaskCatalog();
    catalog.replaceProjectPage(
      [snapshot('one', '/repo'), snapshot('two', '/repo')],
      nextCursor: 'page-2',
    );

    catalog.mergeProjectHead(
      [snapshot('new', '/repo'), snapshot('one', '/repo')],
      nextCursor: 'new-page-2',
    );

    expect(catalog.projectTaskIds, ['new', 'one', 'two']);
    expect(catalog.projectNextCursor, 'page-2');
  });

  test('recent tasks stay ordered by latest update across pages', () {
    final catalog = TaskCatalog();
    final older = snapshot('older', '/repo');
    final newest = TaskSnapshot(
      id: 'newest',
      title: 'Newest',
      status: TaskStatus.completed,
      cwd: '/repo',
      updatedAt: DateTime.utc(2026, 9, 2),
      items: const [],
    );
    final middle = TaskSnapshot(
      id: 'middle',
      title: 'Middle',
      status: TaskStatus.completed,
      cwd: '/repo',
      updatedAt: DateTime.utc(2026, 8, 15),
      items: const [],
    );

    catalog.replaceRecentPage([older, newest], nextCursor: 'page-2');
    catalog.appendRecentPage([middle], nextCursor: null);

    expect(catalog.recentTaskIds, ['newest', 'middle', 'older']);
    expect(catalog.recentNextCursor, isNull);
  });

  test('a stale detail completion cannot clear a newer selection', () {
    final state = TaskDetailLoadState();
    final first = state.begin('first');
    final second = state.begin('second');

    state.complete(first);
    expect(state.loadingTaskId, 'second');

    state.fail(second, 'Could not read task');
    expect(state.loadingTaskId, isNull);
    expect(state.taskId, 'second');
    expect(state.error, 'Could not read task');
  });

  test('starting initial history for a new task rejects the stale page', () {
    final state = TaskHistoryLoadState();
    final first = state.beginInitial('first');
    final second = state.beginInitial('second');

    expect(state.complete(first, nextCursor: 'stale'), isFalse);
    expect(state.taskId, 'second');
    expect(state.isInitialLoading, isTrue);

    expect(state.complete(second, nextCursor: 'older'), isTrue);
    expect(state.isInitialLoading, isFalse);
    expect(state.hasOlder, isTrue);
  });

  test('older history requests are single flight and advance the cursor', () {
    final state = TaskHistoryLoadState();
    final initial = state.beginInitial('task');
    state.complete(initial, nextCursor: 'page-2');

    final older = state.beginOlder();

    expect(older?.taskId, 'task');
    expect(older?.cursor, 'page-2');
    expect(state.beginOlder(), isNull);
    expect(state.isLoadingOlder, isTrue);

    expect(state.complete(older!, nextCursor: 'page-3'), isTrue);
    expect(state.isLoadingOlder, isFalse);
    expect(state.nextCursor, 'page-3');
  });

  test('an older page failure stays inline and preserves its retry cursor', () {
    final state = TaskHistoryLoadState();
    final initial = state.beginInitial('task');
    state.complete(initial, nextCursor: 'page-2');
    final older = state.beginOlder()!;

    expect(state.fail(older, 'Could not load earlier context'), isTrue);

    expect(state.isLoadingOlder, isFalse);
    expect(state.olderError, 'Could not load earlier context');
    expect(state.nextCursor, 'page-2');
    expect(state.beginOlder()?.cursor, 'page-2');
  });
}
