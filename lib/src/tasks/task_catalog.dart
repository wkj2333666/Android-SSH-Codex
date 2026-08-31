import '../projects/remote_project.dart';
import 'task_reducer.dart';

final class TaskCatalog {
  List<String> _projectTaskIds = const [];
  List<String> _unassignedTaskIds = const [];
  String? _projectNextCursor;
  String? _unassignedNextCursor;
  bool _unassignedExpanded = false;

  List<String> get projectTaskIds => _projectTaskIds;
  List<String> get unassignedTaskIds => _unassignedTaskIds;
  String? get projectNextCursor => _projectNextCursor;
  String? get unassignedNextCursor => _unassignedNextCursor;
  bool get unassignedExpanded => _unassignedExpanded;

  void replaceProjectPage(
    List<TaskSnapshot> tasks, {
    required String? nextCursor,
  }) {
    _projectTaskIds = _uniqueIds(tasks);
    _projectNextCursor = nextCursor;
  }

  void appendProjectPage(
    List<TaskSnapshot> tasks, {
    required String? nextCursor,
  }) {
    _projectTaskIds = _appendUnique(_projectTaskIds, tasks);
    _projectNextCursor = nextCursor;
  }

  void mergeProjectHead(
    List<TaskSnapshot> tasks, {
    required String? nextCursor,
  }) {
    final previousCursor = _projectNextCursor;
    _projectTaskIds = _mergeHead(_projectTaskIds, tasks);
    _projectNextCursor = previousCursor ?? nextCursor;
  }

  void replaceUnassignedPage(
    List<TaskSnapshot> tasks, {
    required List<RemoteProject> projects,
    required String? nextCursor,
  }) {
    _unassignedTaskIds = _uniqueIds(_unassigned(tasks, projects));
    _unassignedNextCursor = nextCursor;
  }

  void appendUnassignedPage(
    List<TaskSnapshot> tasks, {
    required List<RemoteProject> projects,
    required String? nextCursor,
  }) {
    _unassignedTaskIds = _appendUnique(
      _unassignedTaskIds,
      _unassigned(tasks, projects),
    );
    _unassignedNextCursor = nextCursor;
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
    _projectTaskIds = const [];
    _projectNextCursor = null;
  }

  void clear() {
    clearProjectPage();
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
