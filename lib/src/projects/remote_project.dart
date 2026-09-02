final class RemoteProject {
  const RemoteProject({
    required this.id,
    required this.hostId,
    required this.name,
    required this.cwd,
  });

  factory RemoteProject.fromJson(Map<String, dynamic> json) => RemoteProject(
        id: json['id'] as String,
        hostId: json['hostId'] as String,
        name: json['name'] as String,
        cwd: json['cwd'] as String,
      );

  final String id;
  final String hostId;
  final String name;
  final String cwd;

  RemoteProject copyWith({
    String? id,
    String? hostId,
    String? name,
    String? cwd,
  }) =>
      RemoteProject(
        id: id ?? this.id,
        hostId: hostId ?? this.hostId,
        name: name ?? this.name,
        cwd: cwd ?? this.cwd,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'hostId': hostId,
        'name': name,
        'cwd': cwd,
      };

  @override
  bool operator ==(Object other) =>
      other is RemoteProject &&
      other.id == id &&
      other.hostId == hostId &&
      other.name == name &&
      other.cwd == cwd;

  @override
  int get hashCode => Object.hash(id, hostId, name, cwd);
}

List<RemoteProject> mergeRemoteProjects({
  required String hostId,
  required Iterable<RemoteProject> existing,
  required Iterable<String> discoveredCwds,
  Map<String, DateTime> activityByCwd = const {},
}) {
  final normalizedActivity = <String, DateTime>{};
  for (final entry in activityByCwd.entries) {
    final cwd = normalizeRemoteCwd(entry.key);
    if (cwd.isEmpty) continue;
    final current = normalizedActivity[cwd];
    if (current == null || entry.value.isAfter(current)) {
      normalizedActivity[cwd] = entry.value;
    }
  }
  final projectsByCwd = <String, RemoteProject>{};
  for (final project in existing) {
    if (project.hostId != hostId) continue;
    final cwd = normalizeRemoteCwd(project.cwd);
    if (cwd.isEmpty) continue;
    projectsByCwd.putIfAbsent(
      cwd,
      () => project.copyWith(cwd: cwd),
    );
  }
  for (final rawCwd in discoveredCwds) {
    final cwd = normalizeRemoteCwd(rawCwd);
    if (cwd.isEmpty || projectsByCwd.containsKey(cwd)) continue;
    projectsByCwd[cwd] = RemoteProject(
      id: _automaticProjectId(hostId, cwd),
      hostId: hostId,
      name: _automaticProjectName(cwd),
      cwd: cwd,
    );
  }
  final projects = projectsByCwd.values.toList(growable: false)
    ..sort((first, second) {
      final firstActivity = normalizedActivity[normalizeRemoteCwd(first.cwd)];
      final secondActivity = normalizedActivity[normalizeRemoteCwd(second.cwd)];
      if (firstActivity != null || secondActivity != null) {
        if (firstActivity == null) return 1;
        if (secondActivity == null) return -1;
        final byActivity = secondActivity.compareTo(firstActivity);
        if (byActivity != 0) return byActivity;
      }
      final byName = first.name.toLowerCase().compareTo(
            second.name.toLowerCase(),
          );
      return byName == 0 ? first.cwd.compareTo(second.cwd) : byName;
    });
  return List.unmodifiable(projects);
}

String normalizeRemoteCwd(String cwd) {
  final normalized = cwd.trim();
  if (normalized.length <= 1) return normalized;
  return normalized.replaceFirst(RegExp(r'/+$'), '');
}

String _automaticProjectId(String hostId, String cwd) =>
    'cwd:${Uri.encodeComponent(hostId)}:${Uri.encodeComponent(cwd)}';

String _automaticProjectName(String cwd) {
  final parts = cwd.split('/').where((part) => part.isNotEmpty);
  return parts.isEmpty ? cwd : parts.last;
}
