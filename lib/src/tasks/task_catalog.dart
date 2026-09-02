import '../projects/remote_project.dart';
import 'task_reducer.dart';

final class TaskPageContinuation {
  const TaskPageContinuation({required this.cursor, required this.generation});

  final String cursor;
  final int generation;
}

final class TaskCatalog {
  List<String> _projectTaskIds = const [];
  List<String> _recentTaskIds = const [];
  List<String> _unassignedTaskIds = const [];
  String? _projectNextCursor;
  String? _recentNextCursor;
  String? _unassignedNextCursor;
  final Map<String, DateTime> _recentUpdatedAt = {};
  var _projectGeneration = 0;
  var _recentGeneration = 0;
  var _unassignedGeneration = 0;
  bool _unassignedExpanded = false;

  List<String> get projectTaskIds => _projectTaskIds;
  List<String> get recentTaskIds => _recentTaskIds;
  List<String> get unassignedTaskIds => _unassignedTaskIds;
  String? get projectNextCursor => _projectNextCursor;
  String? get recentNextCursor => _recentNextCursor;
  String? get unassignedNextCursor => _unassignedNextCursor;
  bool get unassignedExpanded => _unassignedExpanded;
  TaskPageContinuation? get projectContinuation => _projectNextCursor == null
      ? null
      : TaskPageContinuation(
          cursor: _projectNextCursor!,
          generation: _projectGeneration,
        );
  TaskPageContinuation? get recentContinuation => _recentNextCursor == null
      ? null
      : TaskPageContinuation(
          cursor: _recentNextCursor!,
          generation: _recentGeneration,
        );
  TaskPageContinuation? get unassignedContinuation =>
      _unassignedNextCursor == null
          ? null
          : TaskPageContinuation(
              cursor: _unassignedNextCursor!,
              generation: _unassignedGeneration,
            );
  int get projectGeneration => _projectGeneration;

  bool isCurrentProjectGeneration(int generation) =>
      generation == _projectGeneration;

  bool isCurrentProjectContinuation(TaskPageContinuation continuation) =>
      continuation.generation == _projectGeneration &&
      continuation.cursor == _projectNextCursor;

  bool isCurrentRecentContinuation(TaskPageContinuation continuation) =>
      continuation.generation == _recentGeneration &&
      continuation.cursor == _recentNextCursor;

  bool isCurrentUnassignedContinuation(TaskPageContinuation continuation) =>
      continuation.generation == _unassignedGeneration &&
      continuation.cursor == _unassignedNextCursor;

  void replaceProjectPage(
    List<TaskSnapshot> tasks, {
    required String? nextCursor,
  }) {
    _projectGeneration++;
    _projectTaskIds = _uniqueIds(tasks);
    _projectNextCursor = nextCursor;
  }

  bool appendProjectPage(
    TaskPageContinuation continuation,
    List<TaskSnapshot> tasks, {
    required String? nextCursor,
  }) {
    if (!isCurrentProjectContinuation(continuation)) return false;
    _projectTaskIds = _appendUnique(_projectTaskIds, tasks);
    _projectNextCursor = nextCursor;
    return true;
  }

  void mergeProjectHead(
    List<TaskSnapshot> tasks, {
    required String? nextCursor,
  }) {
    final previousCursor = _projectNextCursor;
    _projectTaskIds = _mergeHead(_projectTaskIds, tasks);
    _projectNextCursor = previousCursor ?? nextCursor;
  }

  void replaceRecentPage(
    List<TaskSnapshot> tasks, {
    required String? nextCursor,
  }) {
    _recentGeneration++;
    _recentTaskIds = const [];
    _recentUpdatedAt.clear();
    _mergeRecentTasks(tasks);
    _recentNextCursor = nextCursor;
  }

  bool appendRecentPage(
    TaskPageContinuation continuation,
    List<TaskSnapshot> tasks, {
    required String? nextCursor,
  }) {
    if (!isCurrentRecentContinuation(continuation)) return false;
    _mergeRecentTasks(tasks);
    _recentNextCursor = nextCursor;
    return true;
  }

  void mergeRecentHead(
    List<TaskSnapshot> tasks, {
    required String? nextCursor,
  }) {
    final previousCursor = _recentNextCursor;
    _mergeRecentTasks(tasks);
    _recentNextCursor = previousCursor ?? nextCursor;
  }

  void _mergeRecentTasks(Iterable<TaskSnapshot> tasks) {
    final ids = {..._recentTaskIds};
    for (final task in tasks) {
      ids.add(task.id);
      final current = _recentUpdatedAt[task.id];
      if (current == null || task.updatedAt.isAfter(current)) {
        _recentUpdatedAt[task.id] = task.updatedAt;
      }
    }
    final sorted = ids.toList(growable: false)
      ..sort((first, second) {
        final firstUpdatedAt = _recentUpdatedAt[first]!;
        final secondUpdatedAt = _recentUpdatedAt[second]!;
        final byUpdate = secondUpdatedAt.compareTo(firstUpdatedAt);
        return byUpdate == 0 ? first.compareTo(second) : byUpdate;
      });
    _recentTaskIds = List.unmodifiable(sorted);
  }

  void replaceUnassignedPage(
    List<TaskSnapshot> tasks, {
    required List<RemoteProject> projects,
    required String? nextCursor,
  }) {
    _unassignedGeneration++;
    _unassignedTaskIds = _uniqueIds(_unassigned(tasks, projects));
    _unassignedNextCursor = nextCursor;
  }

  bool appendUnassignedPage(
    TaskPageContinuation continuation,
    List<TaskSnapshot> tasks, {
    required List<RemoteProject> projects,
    required String? nextCursor,
  }) {
    if (!isCurrentUnassignedContinuation(continuation)) return false;
    _unassignedTaskIds = _appendUnique(
      _unassignedTaskIds,
      _unassigned(tasks, projects),
    );
    _unassignedNextCursor = nextCursor;
    return true;
  }

  void mergeUnassignedHead(
    List<TaskSnapshot> tasks, {
    required List<RemoteProject> projects,
    required String? nextCursor,
  }) {
    final previousCursor = _unassignedNextCursor;
    _unassignedTaskIds = _mergeHead(
      _unassignedTaskIds,
      _unassigned(tasks, projects),
    );
    _unassignedNextCursor = previousCursor ?? nextCursor;
  }

  void toggleUnassigned() {
    _unassignedExpanded = !_unassignedExpanded;
  }

  void clearProjectPage() {
    _projectGeneration++;
    _projectTaskIds = const [];
    _projectNextCursor = null;
  }

  void clear() {
    clearProjectPage();
    _recentGeneration++;
    _recentTaskIds = const [];
    _recentNextCursor = null;
    _recentUpdatedAt.clear();
    _unassignedGeneration++;
    _unassignedTaskIds = const [];
    _unassignedNextCursor = null;
    _unassignedExpanded = false;
  }
}

final class TaskDetailLoadState {
  var _generation = 0;
  String? _taskId;
  String? _loadingTaskId;
  String? _error;

  String? get taskId => _taskId;
  String? get loadingTaskId => _loadingTaskId;
  String? get error => _error;

  int begin(String taskId) {
    _generation++;
    _taskId = taskId;
    _loadingTaskId = taskId;
    _error = null;
    return _generation;
  }

  void complete(int generation) {
    if (generation != _generation) return;
    _loadingTaskId = null;
    _error = null;
  }

  void fail(int generation, String error) {
    if (generation != _generation) return;
    _loadingTaskId = null;
    _error = error;
  }

  void clear() {
    _generation++;
    _taskId = null;
    _loadingTaskId = null;
    _error = null;
  }
}

final class TaskHistoryPageToken {
  const TaskHistoryPageToken._({
    required this.taskId,
    required this.cursor,
    required this.generation,
    required this.isInitial,
  });

  final String taskId;
  final String? cursor;
  final int generation;
  final bool isInitial;
}

final class TaskHistoryLoadState {
  var _generation = 0;
  String? _taskId;
  String? _nextCursor;
  bool _isInitialLoading = false;
  bool _isLoadingOlder = false;
  String? _initialError;
  String? _olderError;

  String? get taskId => _taskId;
  String? get nextCursor => _nextCursor;
  bool get hasOlder => _nextCursor != null;
  bool get isInitialLoading => _isInitialLoading;
  bool get isLoadingOlder => _isLoadingOlder;
  String? get initialError => _initialError;
  String? get olderError => _olderError;

  TaskHistoryPageToken beginInitial(String taskId) {
    _generation++;
    _taskId = taskId;
    _nextCursor = null;
    _isInitialLoading = true;
    _isLoadingOlder = false;
    _initialError = null;
    _olderError = null;
    return TaskHistoryPageToken._(
      taskId: taskId,
      cursor: null,
      generation: _generation,
      isInitial: true,
    );
  }

  TaskHistoryPageToken? beginOlder() {
    final taskId = _taskId;
    final cursor = _nextCursor;
    if (taskId == null ||
        cursor == null ||
        _isInitialLoading ||
        _isLoadingOlder) {
      return null;
    }
    _generation++;
    _isLoadingOlder = true;
    _olderError = null;
    return TaskHistoryPageToken._(
      taskId: taskId,
      cursor: cursor,
      generation: _generation,
      isInitial: false,
    );
  }

  bool complete(
    TaskHistoryPageToken token, {
    required String? nextCursor,
  }) {
    if (!_accepts(token)) return false;
    _nextCursor = nextCursor;
    if (token.isInitial) {
      _isInitialLoading = false;
      _initialError = null;
    } else {
      _isLoadingOlder = false;
      _olderError = null;
    }
    return true;
  }

  bool fail(TaskHistoryPageToken token, String error) {
    if (!_accepts(token)) return false;
    if (token.isInitial) {
      _isInitialLoading = false;
      _initialError = error;
    } else {
      _isLoadingOlder = false;
      _olderError = error;
    }
    return true;
  }

  void clear() {
    _generation++;
    _taskId = null;
    _nextCursor = null;
    _isInitialLoading = false;
    _isLoadingOlder = false;
    _initialError = null;
    _olderError = null;
  }

  bool _accepts(TaskHistoryPageToken token) =>
      token.generation == _generation && token.taskId == _taskId;
}

List<TaskSnapshot> _unassigned(
  List<TaskSnapshot> tasks,
  List<RemoteProject> projects,
) {
  final projectCwds =
      projects.map((project) => normalizeRemoteCwd(project.cwd)).toSet();
  return tasks
      .where((task) => !projectCwds.contains(normalizeRemoteCwd(task.cwd)))
      .toList(growable: false);
}

List<String> _uniqueIds(Iterable<TaskSnapshot> tasks) =>
    List.unmodifiable(tasks.map((task) => task.id).toSet());

List<String> _appendUnique(
  List<String> existing,
  Iterable<TaskSnapshot> tasks,
) =>
    List.unmodifiable({...existing, ...tasks.map((task) => task.id)});

List<String> _mergeHead(
  List<String> existing,
  Iterable<TaskSnapshot> tasks,
) =>
    List.unmodifiable({...tasks.map((task) => task.id), ...existing});
