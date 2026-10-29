import 'dart:convert';

import '../projects/remote_project.dart';
import 'host_profile.dart';
import 'secure_key_value_store.dart';

abstract interface class ProfileStore {
  Future<List<HostProfile>> readProfiles();
  Future<void> writeProfile(HostProfile profile, HostSecret secret);
  Future<void> deleteProfile(String id);
  Future<HostSecret> readSecret(String id);
  Future<String?> readAutoConnectHostId();
  Future<void> writeAutoConnectHostId(String? profileId);
  Future<String?> readHostFingerprint(String profileId);
  Future<void> writeHostFingerprint(String profileId, String fingerprint);
  Future<Set<String>> readOwnedThreads(String profileId);
  Future<void> writeOwnedThreads(String profileId, Set<String> threadIds);
  Future<List<RemoteProject>> readProjects(String hostId);
  Future<void> writeProject(RemoteProject project);
  Future<void> deleteProject(String hostId, String projectId);
}

/// Optional durable UI state, kept separate from the host credential contract.
abstract interface class WorkspaceStore {
  Future<Map<String, dynamic>> readWorkspace();
  Future<void> writeWorkspace(Map<String, dynamic> value);
}

final class SecureProfileStore implements ProfileStore, WorkspaceStore {
  SecureProfileStore([SecureKeyValueStore? storage])
      : _storage = storage ?? createSecureKeyValueStore();

  final SecureKeyValueStore _storage;

  @override
  Future<Map<String, dynamic>> readWorkspace() async {
    final raw = await _storage.read(key: 'workspace.v1');
    return raw == null ? {} : (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  @override
  Future<void> writeWorkspace(Map<String, dynamic> value) =>
      _storage.write(key: 'workspace.v1', value: jsonEncode(value));

  @override
  Future<List<HostProfile>> readProfiles() async {
    final value = await _storage.read(key: 'profiles');
    if (value == null || value.isEmpty) return [];
    final decoded = jsonDecode(value) as List<dynamic>;
    return decoded
        .map((item) =>
            HostProfile.fromJson((item as Map).cast<String, dynamic>()))
        .toList(growable: false);
  }

  @override
  Future<void> writeProfile(HostProfile profile, HostSecret secret) async {
    final profiles = (await readProfiles()).toList();
    final index = profiles.indexWhere((item) => item.id == profile.id);
    final jumpChanged =
        index >= 0 && _jumpEndpointChanged(profiles[index], profile);
    if (index == -1) {
      profiles.add(profile);
    } else {
      profiles[index] = profile;
    }
    await _storage.write(
      key: 'profiles',
      value: jsonEncode(profiles.map((item) => item.toJson()).toList()),
    );
    await _storage.write(
      key: 'secret.${profile.id}',
      value: jsonEncode(secret.toJson()),
    );
    if (jumpChanged) {
      await _storage.delete(key: 'fingerprint.${profile.id}.jump');
    }
  }

  @override
  Future<void> deleteProfile(String id) async {
    final profiles = (await readProfiles())
        .where((profile) => profile.id != id)
        .toList(growable: false);
    await _storage.write(
      key: 'profiles',
      value: jsonEncode(profiles.map((item) => item.toJson()).toList()),
    );
    await _storage.delete(key: 'secret.$id');
    await _storage.delete(key: 'fingerprint.$id');
    await _storage.delete(key: 'fingerprint.$id.jump');
    await _storage.delete(key: 'owned.$id');
    await _storage.delete(key: 'projects.$id');
    if (await readAutoConnectHostId() == id) {
      await writeAutoConnectHostId(null);
    }
  }

  @override
  Future<HostSecret> readSecret(String id) async {
    final value = await _storage.read(key: 'secret.$id');
    if (value == null || value.isEmpty) return const HostSecret();
    return HostSecret.fromJson(
      (jsonDecode(value) as Map).cast<String, dynamic>(),
    );
  }

  @override
  Future<String?> readAutoConnectHostId() =>
      _storage.read(key: 'autoConnectHostId');

  @override
  Future<void> writeAutoConnectHostId(String? profileId) => profileId == null
      ? _storage.delete(key: 'autoConnectHostId')
      : _storage.write(key: 'autoConnectHostId', value: profileId);

  @override
  Future<String?> readHostFingerprint(String profileId) =>
      _storage.read(key: 'fingerprint.$profileId');

  @override
  Future<void> writeHostFingerprint(
    String profileId,
    String fingerprint,
  ) =>
      _storage.write(key: 'fingerprint.$profileId', value: fingerprint);

  @override
  Future<Set<String>> readOwnedThreads(String profileId) async {
    final value = await _storage.read(key: 'owned.$profileId');
    if (value == null || value.isEmpty) return <String>{};
    return (jsonDecode(value) as List<dynamic>).cast<String>().toSet();
  }

  @override
  Future<void> writeOwnedThreads(
    String profileId,
    Set<String> threadIds,
  ) =>
      _storage.write(
          key: 'owned.$profileId', value: jsonEncode(threadIds.toList()));

  @override
  Future<List<RemoteProject>> readProjects(String hostId) async {
    final value = await _storage.read(key: 'projects.$hostId');
    if (value == null || value.isEmpty) return [];
    final projects = (jsonDecode(value) as List<dynamic>)
        .map((item) =>
            RemoteProject.fromJson((item as Map).cast<String, dynamic>()))
        .where((project) => project.hostId == hostId)
        .toList(growable: false);
    return _sortProjects(projects);
  }

  @override
  Future<void> writeProject(RemoteProject project) async {
    final projects = (await readProjects(project.hostId)).toList();
    final index = projects.indexWhere((item) => item.id == project.id);
    if (index == -1) {
      projects.add(project);
    } else {
      projects[index] = project;
    }
    await _writeProjects(project.hostId, projects);
  }

  @override
  Future<void> deleteProject(String hostId, String projectId) async {
    final projects = (await readProjects(hostId))
        .where((project) => project.id != projectId)
        .toList(growable: false);
    await _writeProjects(hostId, projects);
  }

  Future<void> _writeProjects(
    String hostId,
    List<RemoteProject> projects,
  ) async {
    if (projects.isEmpty) {
      await _storage.delete(key: 'projects.$hostId');
      return;
    }
    await _storage.write(
      key: 'projects.$hostId',
      value: jsonEncode(projects.map((project) => project.toJson()).toList()),
    );
  }
}

final class MemoryProfileStore implements ProfileStore, WorkspaceStore {
  Map<String, dynamic> _workspace = {};

  @override
  Future<Map<String, dynamic>> readWorkspace() async =>
      (jsonDecode(jsonEncode(_workspace)) as Map).cast<String, dynamic>();

  @override
  Future<void> writeWorkspace(Map<String, dynamic> value) async {
    _workspace = (jsonDecode(jsonEncode(value)) as Map).cast<String, dynamic>();
  }

  final Map<String, HostProfile> _profiles = {};
  final Map<String, HostSecret> _secrets = {};
  final Map<String, String> _fingerprints = {};
  final Map<String, Set<String>> _owned = {};
  final Map<String, Map<String, RemoteProject>> _projects = {};
  String? _autoConnectHostId;

  @override
  Future<List<HostProfile>> readProfiles() async =>
      _profiles.values.toList(growable: false);

  @override
  Future<void> writeProfile(HostProfile profile, HostSecret secret) async {
    if (_jumpEndpointChanged(_profiles[profile.id], profile)) {
      _fingerprints.remove('${profile.id}.jump');
    }
    _profiles[profile.id] = profile;
    _secrets[profile.id] = secret;
  }

  @override
  Future<void> deleteProfile(String id) async {
    _profiles.remove(id);
    _secrets.remove(id);
    _fingerprints.remove(id);
    _fingerprints.remove('$id.jump');
    _owned.remove(id);
    _projects.remove(id);
    if (_autoConnectHostId == id) _autoConnectHostId = null;
  }

  @override
  Future<HostSecret> readSecret(String id) async =>
      _secrets[id] ?? const HostSecret();

  @override
  Future<String?> readAutoConnectHostId() async => _autoConnectHostId;

  @override
  Future<void> writeAutoConnectHostId(String? profileId) async {
    _autoConnectHostId = profileId;
  }

  @override
  Future<String?> readHostFingerprint(String profileId) async =>
      _fingerprints[profileId];

  @override
  Future<void> writeHostFingerprint(
    String profileId,
    String fingerprint,
  ) async {
    _fingerprints[profileId] = fingerprint;
  }

  @override
  Future<Set<String>> readOwnedThreads(String profileId) async =>
      Set<String>.of(_owned[profileId] ?? const {});

  @override
  Future<void> writeOwnedThreads(
    String profileId,
    Set<String> threadIds,
  ) async {
    _owned[profileId] = Set<String>.of(threadIds);
  }

  @override
  Future<List<RemoteProject>> readProjects(String hostId) async =>
      _sortProjects(_projects[hostId]?.values ?? const <RemoteProject>[]);

  @override
  Future<void> writeProject(RemoteProject project) async {
    _projects.putIfAbsent(project.hostId, () => {})[project.id] = project;
  }

  @override
  Future<void> deleteProject(String hostId, String projectId) async {
    _projects[hostId]?.remove(projectId);
    if (_projects[hostId]?.isEmpty ?? false) _projects.remove(hostId);
  }
}

List<RemoteProject> _sortProjects(Iterable<RemoteProject> projects) {
  final sorted = projects.toList(growable: false);
  sorted.sort(
    (first, second) =>
        first.name.toLowerCase().compareTo(second.name.toLowerCase()),
  );
  return List.unmodifiable(sorted);
}

bool _jumpEndpointChanged(HostProfile? previous, HostProfile next) =>
    previous != null &&
    (previous.proxyJump?.hostName != next.proxyJump?.hostName ||
        previous.proxyJump?.port != next.proxyJump?.port);
