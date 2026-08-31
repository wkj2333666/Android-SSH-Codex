import 'dart:async';
import 'dart:convert';

import '../tasks/task_reducer.dart';
import 'json_rpc_client.dart';

final class RemoteTaskBatch {
  const RemoteTaskBatch({required this.tasks, required this.loadedThreadIds});

  final List<TaskSnapshot> tasks;
  final Set<String> loadedThreadIds;
}

final class RemoteTaskPage {
  const RemoteTaskPage({required this.tasks, required this.nextCursor});

  final List<TaskSnapshot> tasks;
  final String? nextCursor;
}

final class RemoteTurnPage {
  const RemoteTurnPage({required this.items, required this.nextCursor});

  final List<TaskItem> items;
  final String? nextCursor;
}

final class RemoteSkill {
  const RemoteSkill({
    required this.name,
    required this.description,
    required this.path,
  });

  final String name;
  final String description;
  final String path;
}

final class RemoteReasoningEffort {
  const RemoteReasoningEffort({
    required this.effort,
    required this.description,
  });

  final String effort;
  final String description;
}

final class RemoteModel {
  const RemoteModel({
    required this.id,
    required this.model,
    required this.displayName,
    required this.description,
    required this.isDefault,
    required this.defaultReasoningEffort,
    required this.supportedReasoningEfforts,
  });

  final String id;
  final String model;
  final String displayName;
  final String description;
  final bool isDefault;
  final String defaultReasoningEffort;
  final List<RemoteReasoningEffort> supportedReasoningEfforts;
}

final class RemoteThreadGoal {
  const RemoteThreadGoal({
    required this.objective,
    required this.status,
    required this.tokenBudget,
    required this.tokensUsed,
    required this.timeUsedSeconds,
  });

  final String objective;
  final String status;
  final int? tokenBudget;
  final int tokensUsed;
  final int timeUsedSeconds;
}

final class PendingApproval {
  const PendingApproval({
    required this.requestId,
    required this.method,
    required this.threadId,
    required this.title,
    required this.detail,
    required this.availableDecisions,
  });

  final Object requestId;
  final String method;
  final String threadId;
  final String title;
  final String detail;
  final List<String> availableDecisions;
}

final class CodexRemoteApi {
  CodexRemoteApi(this._rpc);

  final JsonRpcClient _rpc;

  Stream<RpcNotification> get notifications => _rpc.notifications;
  Stream<RpcServerRequest> get serverRequests => _rpc.serverRequests;

  Future<void> initialize() async {
    await _rpc.request('initialize', {
      'clientInfo': {
        'name': 'android_ssh_codex',
        'title': 'Android SSH Codex',
        'version': '0.1.0',
      },
      'capabilities': {
        'experimentalApi': true,
      },
    });
    _rpc.notify('initialized', const {});
  }

  Future<RemoteTaskBatch> readTaskBatch() async {
    final page = await readTaskPage();
    final loaded = await readLoadedThreadIds();
    return RemoteTaskBatch(tasks: page.tasks, loadedThreadIds: loaded);
  }

  Future<RemoteTaskPage> readTaskPage({String? cwd, String? cursor}) async {
    final result = _map(await _rpc.request('thread/list', {
      'limit': 20,
      'archived': false,
      'sortKey': 'recency_at',
      'sortDirection': 'desc',
      if (cwd != null) 'cwd': cwd,
      if (cursor != null) 'cursor': cursor,
    }));
    final data = result['data'] as List<dynamic>? ?? const [];
    return RemoteTaskPage(
      tasks: List.unmodifiable(
        data.map((item) => parseThread(_map(item))),
      ),
      nextCursor: result['nextCursor'] as String?,
    );
  }

  Future<Set<String>> readAllTaskCwds() async {
    final cwds = <String>{};
    final seenCursors = <String>{};
    String? cursor;
    do {
      final page = await readTaskPage(cursor: cursor);
      cwds.addAll(
        page.tasks
            .map((task) => task.cwd.trim())
            .where((cwd) => cwd.isNotEmpty),
      );
      final nextCursor = page.nextCursor;
      cursor = nextCursor != null && seenCursors.add(nextCursor)
          ? nextCursor
          : null;
    } while (cursor != null);
    return Set.unmodifiable(cwds);
  }

  Future<Set<String>> readLoadedThreadIds() async {
    final loadedResult = _map(
      await _rpc.request('thread/loaded/list', const {}),
    );
    final rawLoaded = loadedResult['data'] ?? loadedResult['threadIds'];
    final loaded = rawLoaded is List
        ? rawLoaded
            .map((item) => item is Map ? item['id'] : item)
            .whereType<String>()
            .toSet()
        : <String>{};
    return loaded;
  }

  Future<TaskSnapshot> readThread(String threadId) async {
    final result = _map(await _rpc.request('thread/read', {
      'threadId': threadId,
      'includeTurns': true,
    }));
    return parseThread(_map(result['thread']));
  }

  Future<RemoteTurnPage> readThreadTurnsPage(
    String threadId, {
    String? cursor,
  }) async {
    final result = _map(await _rpc.request('thread/turns/list', {
      'threadId': threadId,
      'limit': 10,
      'sortDirection': 'desc',
      'itemsView': 'full',
      if (cursor != null) 'cursor': cursor,
    }));
    final turns = result['data'] as List<dynamic>? ?? const [];
    final items = <TaskItem>[];
    for (final rawTurn in turns.reversed) {
      final turn = _map(rawTurn);
      for (final rawItem in turn['items'] as List<dynamic>? ?? const []) {
        final item = _parseItem(_map(rawItem));
        if (item != null) items.add(item);
      }
    }
    return RemoteTurnPage(
      items: List.unmodifiable(items),
      nextCursor: result['nextCursor'] as String?,
    );
  }

  Future<String?> readActiveTurnId(String threadId) async {
    final result = _map(await _rpc.request('thread/turns/list', {
      'threadId': threadId,
      'limit': 1,
      'sortDirection': 'desc',
      'itemsView': 'notLoaded',
    }));
    final turns = result['data'] as List<dynamic>? ?? const [];
    for (final rawTurn in turns) {
      final turn = _map(rawTurn);
      if (_isActiveTurnStatus(turn['status'])) {
        return turn['id'] as String?;
      }
    }
    return null;
  }

  Future<String> startThread({required String cwd}) async {
    final result = _map(await _rpc.request('thread/start', {
      'cwd': cwd,
    }));
    return _map(result['thread'])['id'] as String;
  }

  Future<void> resumeThread(String threadId) async {
    await _rpc.request('thread/resume', {
      'threadId': threadId,
      'excludeTurns': true,
    });
  }

  Future<void> startTurn(
    String threadId,
    String text, {
    RemoteSkill? skill,
    String? model,
    String? effort,
  }) async {
    await _rpc.request('turn/start', {
      'threadId': threadId,
      'input': [
        {'type': 'text', 'text': text},
        if (skill != null)
          {
            'type': 'skill',
            'name': skill.name,
            'path': skill.path,
          },
      ],
      if (model != null) 'model': model,
      if (effort != null) 'effort': effort,
    });
  }

  Future<List<RemoteModel>> readModelCatalog() async {
    final models = <RemoteModel>[];
    final seenIds = <String>{};
    String? cursor;
    do {
      final result = _map(await _rpc.request('model/list', {
        'limit': 100,
        'includeHidden': false,
        if (cursor != null) 'cursor': cursor,
      }));
      for (final rawModel in result['data'] as List<dynamic>? ?? const []) {
        final model = _parseModel(_map(rawModel));
        if (model != null && seenIds.add(model.id)) models.add(model);
      }
      final nextCursor = result['nextCursor'] as String?;
      cursor = nextCursor == cursor ? null : nextCursor;
    } while (cursor != null);
    return List.unmodifiable(models);
  }

  Future<List<RemoteSkill>> listSkills(String cwd) async {
    final result = _map(await _rpc.request('skills/list', {
      'cwds': [cwd],
    }));
    final skills = <RemoteSkill>[];
    for (final rawGroup in result['data'] as List<dynamic>? ?? const []) {
      final group = _map(rawGroup);
      for (final rawSkill in group['skills'] as List<dynamic>? ?? const []) {
        final skill = _map(rawSkill);
        final name = skill['name'] as String?;
        final path = skill['path'] as String?;
        if (name == null ||
            name.isEmpty ||
            path == null ||
            path.isEmpty ||
            skill['enabled'] == false) {
          continue;
        }
        skills.add(RemoteSkill(
          name: name,
          description: skill['description'] as String? ?? '',
          path: path,
        ));
      }
    }
    skills.sort((first, second) => first.name.compareTo(second.name));
    return List.unmodifiable(skills);
  }

  Future<RemoteThreadGoal?> readThreadGoal(String threadId) async {
    final result = _map(await _rpc.request('thread/goal/get', {
      'threadId': threadId,
    }));
    return _parseGoal(result['goal']);
  }

  Future<RemoteThreadGoal> setThreadGoal(
    String threadId, {
    required String objective,
    int? tokenBudget,
  }) async {
    final result = _map(await _rpc.request('thread/goal/set', {
      'threadId': threadId,
      'objective': objective,
      'status': 'active',
      if (tokenBudget != null) 'tokenBudget': tokenBudget,
    }));
    return _parseGoal(result['goal'])!;
  }

  Future<void> clearThreadGoal(String threadId) async {
    await _rpc.request('thread/goal/clear', {'threadId': threadId});
  }

  Future<void> compactThread(String threadId) async {
    await _rpc.request('thread/compact/start', {'threadId': threadId});
  }

  Future<void> interruptTurn(String threadId, String turnId) async {
    await _rpc.request('turn/interrupt', {
      'threadId': threadId,
      'turnId': turnId,
    });
  }

  Future<void> steerTurn(
    String threadId,
    String expectedTurnId,
    String text,
  ) async {
    await _rpc.request('turn/steer', {
      'threadId': threadId,
      'expectedTurnId': expectedTurnId,
      'input': [
        {'type': 'text', 'text': text},
      ],
    });
  }

  void answerApproval(Object requestId, String decision) {
    _rpc.respond(requestId, {'decision': decision});
  }

  static TaskSnapshot parseThread(Map<String, dynamic> thread) {
    final id = thread['id'] as String? ?? 'unknown';
    final items = <TaskItem>[];
    final turns = thread['turns'] as List<dynamic>? ?? const [];
    for (final rawTurn in turns) {
      final turn = _map(rawTurn);
      for (final rawItem in turn['items'] as List<dynamic>? ?? const []) {
        final item = _parseItem(_map(rawItem));
        if (item != null) items.add(item);
      }
    }
    final title = _firstText(
          thread['name'],
          thread['title'],
          thread['preview'],
          items
              .where((item) => item.kind == TaskItemKind.user)
              .firstOrNull
              ?.text,
        ) ??
        'Task ${id.length > 8 ? id.substring(0, 8) : id}';
    return TaskSnapshot(
      id: id,
      title: title,
      status: _parseStatus(thread['status']),
      cwd: thread['cwd'] as String? ?? '',
      updatedAt: _parseTime(
        thread['updatedAt'] ?? thread['createdAt'] ?? thread['updated_at'],
      ),
      items: List.unmodifiable(items),
    );
  }

  static TaskEvent? parseNotification(
    String method,
    Map<String, dynamic> params,
  ) {
    final threadId = params['threadId'] as String? ??
        _map(params['thread'])['id'] as String?;
    if (threadId == null) return null;
    switch (method) {
      case 'turn/started':
      case 'thread/started':
        return TaskEvent.statusChanged(threadId, TaskStatus.running);
      case 'turn/completed':
        final status = _parseStatus(_map(params['turn'])['status']);
        return TaskEvent.statusChanged(threadId, status);
      case 'item/agentMessage/delta':
        final itemId = params['itemId'] as String? ?? 'agent-message';
        final sequence = params['sequence'] ?? params['deltaIndex'];
        final delta = params['delta'] as String? ?? '';
        if (delta.isEmpty) return null;
        return TaskEvent.agentDelta(
          threadId,
          itemId,
          sequence == null ? null : '$threadId:$itemId:$sequence',
          delta,
        );
      case 'item/started':
      case 'item/completed':
        final item = _map(params['item']);
        final parsed = _parseItem(item);
        return parsed == null ? null : TaskEvent.itemChanged(threadId, parsed);
      default:
        return null;
    }
  }

  static PendingApproval parseApproval(RpcServerRequest request) {
    final params = request.params;
    final command = params['command'];
    final detail = command is List
        ? command.join(' ')
        : _firstText(command, params['reason'], params['cwd']) ??
            request.method;
    final decisions = (params['availableDecisions'] as List<dynamic>?)
            ?.whereType<String>()
            .toList(growable: false) ??
        const ['accept', 'decline'];
    return PendingApproval(
      requestId: request.id,
      method: request.method,
      threadId: params['threadId'] as String? ?? '',
      title: request.method.contains('fileChange')
          ? 'Approve file changes'
          : 'Approve command',
      detail: detail,
      availableDecisions: decisions,
    );
  }
}

bool _isActiveTurnStatus(Object? raw) {
  final status = raw is Map ? raw['type'] ?? raw['status'] : raw;
  return switch (status?.toString().toLowerCase()) {
    'active' || 'running' || 'inprogress' || 'in_progress' => true,
    _ => false,
  };
}

RemoteThreadGoal? _parseGoal(Object? raw) {
  final goal = _map(raw);
  if (goal.isEmpty) return null;
  final objective = goal['objective'] as String?;
  if (objective == null || objective.isEmpty) return null;
  return RemoteThreadGoal(
    objective: objective,
    status: goal['status'] as String? ?? 'active',
    tokenBudget: (goal['tokenBudget'] as num?)?.toInt(),
    tokensUsed: (goal['tokensUsed'] as num?)?.toInt() ?? 0,
    timeUsedSeconds: (goal['timeUsedSeconds'] as num?)?.toInt() ?? 0,
  );
}

TaskItem? _parseItem(Map<String, dynamic> item) {
  final type = item['type'] as String? ?? 'unknown';
  final id = item['id'] as String? ?? '$type-${item.hashCode}';
  final text = _extractText(item);
  final kind = switch (type) {
    'userMessage' => TaskItemKind.user,
    'agentMessage' => TaskItemKind.agent,
    'commandExecution' => TaskItemKind.command,
    'fileChange' => TaskItemKind.file,
    'mcpToolCall' || 'dynamicToolCall' => TaskItemKind.tool,
    'reasoning' => TaskItemKind.reasoning,
    _ => TaskItemKind.notice,
  };
  if ((kind == TaskItemKind.user || kind == TaskItemKind.agent) &&
      text.trim().isEmpty) {
    return null;
  }
  final presentation = _itemPresentation(type, item, text);
  return TaskItem(
    id: id,
    kind: kind,
    title: presentation.title,
    text: presentation.text,
    detail: presentation.detail,
    status: item['status']?.toString(),
  );
}

_ItemPresentation _itemPresentation(
  String type,
  Map<String, dynamic> item,
  String extractedText,
) {
  switch (type) {
    case 'reasoning':
      final summary = _readTextBlocks(item['summary']);
      final content = _readTextBlocks(item['content']);
      return _ItemPresentation(
        title: 'Reasoning',
        text: summary.isNotEmpty
            ? summary
            : content.isNotEmpty
                ? content
                : 'Reasoning',
        detail: summary.isNotEmpty && content.isNotEmpty && content != summary
            ? content
            : null,
      );
    case 'commandExecution':
      final command = _firstText(item['command']) ?? 'Command';
      final output = _firstText(item['aggregatedOutput'], item['output']);
      final cwd = item['cwd'] as String?;
      return _ItemPresentation(
        title: command,
        text: cwd == null || cwd.isEmpty ? command : cwd,
        detail: output,
      );
    case 'fileChange':
      final changes = item['changes'] as List<dynamic>? ?? const [];
      final lines = <String>[];
      final diffs = <String>[];
      for (final raw in changes) {
        final change = _map(raw);
        final path = change['path'] as String? ?? 'unknown file';
        final changeKind = change['kind']?.toString() ?? 'change';
        lines.add('$changeKind  $path');
        final diff = change['diff'] as String?;
        if (diff != null && diff.isNotEmpty) diffs.add('$path\n$diff');
      }
      return _ItemPresentation(
        title: changes.length == 1
            ? '1 file changed'
            : '${changes.length} files changed',
        text: lines.isEmpty ? 'File changes' : lines.join('\n'),
        detail: diffs.isEmpty ? null : diffs.join('\n\n'),
      );
    case 'mcpToolCall':
      final server = item['server']?.toString();
      final tool = item['tool']?.toString() ?? 'Tool';
      return _ItemPresentation(
        title: server == null || server.isEmpty ? tool : '$server · $tool',
        text: tool,
        detail: _jsonDetail(item, const ['arguments', 'result', 'error']),
      );
    case 'dynamicToolCall':
      final tool = item['tool']?.toString() ?? 'Tool';
      return _ItemPresentation(
        title: tool,
        text: tool,
        detail: _jsonDetail(
          item,
          const ['arguments', 'contentItems', 'success'],
        ),
      );
    default:
      return _ItemPresentation(
        text: extractedText.isEmpty ? type : extractedText,
      );
  }
}

String _readTextBlocks(Object? raw) {
  if (raw is String) return raw.trim();
  if (raw is List) {
    return raw
        .map((part) => part is String ? part : _map(part)['text'])
        .whereType<String>()
        .where((part) => part.trim().isNotEmpty)
        .join('\n')
        .trim();
  }
  return '';
}

String? _jsonDetail(Map<String, dynamic> item, List<String> keys) {
  final detail = <String, dynamic>{};
  for (final key in keys) {
    if (item[key] != null) detail[key] = item[key];
  }
  if (detail.isEmpty) return null;
  return const JsonEncoder.withIndent('  ').convert(detail);
}

final class _ItemPresentation {
  const _ItemPresentation({required this.text, this.title, this.detail});

  final String? title;
  final String text;
  final String? detail;
}

String _extractText(Map<String, dynamic> item) {
  final direct = _firstText(
    item['text'],
    item['summary'],
    item['command'],
    item['output'],
    item['name'],
  );
  if (direct != null) return direct;
  final content = item['content'];
  if (content is List) {
    return content
        .map((part) => _map(part)['text'])
        .whereType<String>()
        .join('\n');
  }
  return '';
}

TaskStatus _parseStatus(Object? raw) {
  final value = raw is Map ? raw['type'] ?? raw['status'] : raw;
  return switch (value?.toString().toLowerCase()) {
    'active' ||
    'running' ||
    'inprogress' ||
    'in_progress' =>
      TaskStatus.running,
    'queued' || 'pending' => TaskStatus.queued,
    'completed' ||
    'complete' ||
    'idle' ||
    'notloaded' ||
    'not_loaded' =>
      TaskStatus.completed,
    'failed' || 'error' || 'systemerror' => TaskStatus.failed,
    'interrupted' || 'cancelled' || 'canceled' => TaskStatus.interrupted,
    _ => TaskStatus.unknown,
  };
}

DateTime _parseTime(Object? raw) {
  if (raw is num) {
    final milliseconds = raw > 1000000000000 ? raw.toInt() : raw.toInt() * 1000;
    return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  }
  if (raw is String) {
    return DateTime.tryParse(raw)?.toUtc() ?? DateTime.now().toUtc();
  }
  return DateTime.now().toUtc();
}

String? _firstText(
  Object? first, [
  Object? second,
  Object? third,
  Object? fourth,
  Object? fifth,
]) {
  for (final value in [first, second, third, fourth, fifth]) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is List && value.isNotEmpty) return value.join(' ');
  }
  return null;
}

RemoteModel? _parseModel(Map<String, dynamic> raw) {
  final id = raw['id'] as String?;
  final model = raw['model'] as String?;
  final displayName = raw['displayName'] as String?;
  final defaultEffort = raw['defaultReasoningEffort'] as String?;
  if (raw['hidden'] == true ||
      id == null ||
      id.isEmpty ||
      model == null ||
      model.isEmpty ||
      displayName == null ||
      displayName.isEmpty ||
      defaultEffort == null ||
      defaultEffort.isEmpty) {
    return null;
  }
  final efforts = <RemoteReasoningEffort>[];
  for (final rawOption
      in raw['supportedReasoningEfforts'] as List<dynamic>? ?? const []) {
    final option = _map(rawOption);
    final effort = option['reasoningEffort'] as String?;
    if (effort == null || effort.isEmpty) continue;
    efforts.add(RemoteReasoningEffort(
      effort: effort,
      description: option['description'] as String? ?? '',
    ));
  }
  return RemoteModel(
    id: id,
    model: model,
    displayName: displayName,
    description: raw['description'] as String? ?? '',
    isDefault: raw['isDefault'] == true,
    defaultReasoningEffort: defaultEffort,
    supportedReasoningEfforts: List.unmodifiable(efforts),
  );
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  return const {};
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
