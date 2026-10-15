import '../profiles/profile_store.dart';
import '../protocol/codex_remote_api.dart';
import 'remote_project.dart';

/// The server is authoritative. Local records are a cache, except for legacy
/// projects which are imported once, with a stable retry-safe creation key.
final class SharedProjectSync {
  SharedProjectSync(this.api, this.store, this.hostId, this.checkSession);

  final CodexRemoteApi api;
  final ProfileStore store;
  final String hostId;
  final void Function() checkSession;

  Future<List<RemoteProject>> synchronize() async {
    final remote = await api.readProjects(hostId);
    checkSession();
    final cached = await store.readProjects(hostId);
    checkSession();
    for (final local in cached.where((project) => project.remoteId == null)) {
      final matches = remote.where((p) => p.containsCwd(local.cwd)).toList();
      // Do not guess between two shared projects that use the same directory.
      final project =
          matches.length == 1 ? matches.single : await api.createProject(local);
      checkSession();
      if (!remote.any((p) => p.remoteId == project.remoteId)) {
        remote.add(project);
      }
      await adoptUnassignedTasks(project, cwd: local.cwd);
      checkSession();
      // Remove the legacy record only after both the server and cache succeeded.
      await store.writeProject(project);
      checkSession();
      await store.deleteProject(hostId, local.id);
      checkSession();
    }
    for (final project in remote) {
      if (!cached.contains(project)) await store.writeProject(project);
      checkSession();
    }
    for (final local in cached.where((project) => project.remoteId != null)) {
      if (!remote.any((project) => project.remoteId == local.remoteId)) {
        await store.deleteProject(hostId, local.id);
        checkSession();
      }
    }
    return remote;
  }

  Future<void> adoptUnassignedTasks(RemoteProject project,
      {required String cwd}) async {
    final cursors = <String>{};
    String? cursor;
    do {
      checkSession();
      final page = await api.readTaskPage(
        cwd: cwd,
        cursor: cursor,
        sortKey: 'created_at',
      );
      checkSession();
      for (final task in page.tasks) {
        if (task.projectId != null) continue;
        await api.assignThreadProject(task.id, project.remoteId!);
        checkSession();
      }
      cursor = page.nextCursor;
      if (cursor != null && !cursors.add(cursor)) {
        throw StateError(
            'Task pagination repeated a cursor during project migration.');
      }
    } while (cursor != null);
  }
}
