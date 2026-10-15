import 'dart:async';
import 'dart:convert';

import 'package:android_ssh_codex/src/profiles/profile_store.dart';
import 'package:android_ssh_codex/src/projects/remote_project.dart';
import 'package:android_ssh_codex/src/projects/shared_project_sync.dart';
import 'package:android_ssh_codex/src/protocol/codex_remote_api.dart';
import 'package:android_ssh_codex/src/protocol/json_rpc_client.dart';
import 'package:android_ssh_codex/src/protocol/rpc_transport.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Server implements RpcTransport {
  final incoming = StreamController<String>();
  final requests = <Map<String, dynamic>>[];
  final projects = <Map<String, dynamic>>[];
  final threads = <Map<String, dynamic>>[];
  bool failAssignment = false;

  @override
  Stream<String> get messages => incoming.stream;

  @override
  void send(String message) {
    final request = jsonDecode(message) as Map<String, dynamic>;
    requests.add(request);
    final params = request['params'] as Map<String, dynamic>;
    Object result;
    switch (request['method']) {
      case 'project/list':
        result = {'data': projects, 'nextCursor': null};
      case 'project/create':
        final project = {
          'id': 'shared',
          'name': params['name'],
          'roots': params['roots'],
        };
        projects.add(project);
        result = {'project': project};
      case 'thread/list':
        result = {'data': threads, 'nextCursor': null};
      case 'thread/metadata/update':
        if (failAssignment) {
          incoming.add(jsonEncode({
            'id': request['id'],
            'error': {'code': -32000, 'message': 'temporary failure'},
          }));
          return;
        }
        threads.firstWhere((t) => t['id'] == params['threadId'])['projectId'] =
            params['projectId'];
        result = <String, dynamic>{};
      case 'thread/start':
        result = {
          'thread': {'id': 'new-thread'}
        };
      default:
        throw StateError('Unexpected request ${request['method']}');
    }
    incoming.add(jsonEncode({'id': request['id'], 'result': result}));
  }

  @override
  Future<void> close() => incoming.close();
}

void main() {
  const legacy = RemoteProject(
    id: 'local-project',
    hostId: 'pi',
    name: 'Phone project',
    cwd: '/srv/app',
  );
  late _Server server;
  late JsonRpcClient rpc;
  late CodexRemoteApi api;
  late MemoryProfileStore store;
  late SharedProjectSync sync;
  setUp(() {
    server = _Server();
    rpc = JsonRpcClient(server)..start();
    api = CodexRemoteApi(rpc);
    store = MemoryProfileStore();
    sync = SharedProjectSync(api, store, 'pi', () {});
  });
  tearDown(() => rpc.close());

  test('imports local project and unassigned tasks without stealing membership',
      () async {
    await store.writeProject(legacy);
    server.threads.addAll([
      {'id': 'old', 'cwd': '/srv/app'},
      {'id': 'owned', 'cwd': '/srv/app', 'projectId': 'other'},
    ]);
    final projects = await sync.synchronize();
    expect(projects.single.remoteId, 'shared');
    expect(server.threads.first['projectId'], 'shared');
    expect(server.threads.last['projectId'], 'other');
    expect((await store.readProjects('pi')).single.remoteId, 'shared');
    final creates =
        server.requests.where((r) => r['method'] == 'project/create');
    expect(creates.single['params']['idempotencyKey'],
        'android-ssh-codex:local-project');
    await sync.synchronize();
    expect(creates, hasLength(1));
  });

  test('matches Desktop project by any root and preserves its name', () async {
    await store.writeProject(legacy);
    server.projects.add({
      'id': 'desktop',
      'name': 'Desktop name',
      'roots': [
        {'path': '/srv/other'},
        {'path': '/srv/app'}
      ],
    });
    final projects = await sync.synchronize();
    expect(projects.single.name, 'Desktop name');
    expect(projects.single.additionalRoots, ['/srv/app']);
    expect(
        server.requests.where((r) => r['method'] == 'project/create'), isEmpty);
    expect(RemoteProject.fromJson(projects.single.toJson()), projects.single);
  });

  test('remote deletion removes cache without recreating the project',
      () async {
    await store.writeProject(
        legacy.copyWith(id: 'remote:deleted', remoteId: 'deleted'));
    expect(await sync.synchronize(), isEmpty);
    expect(await store.readProjects('pi'), isEmpty);
    expect(server.requests.map((r) => r['method']), ['project/list']);
  });

  test('failed migration retries assignment without duplicating the project',
      () async {
    await store.writeProject(legacy);
    server.threads.add({'id': 'old', 'cwd': '/srv/app'});
    server.failAssignment = true;
    await expectLater(sync.synchronize(), throwsA(isA<RpcRemoteException>()));
    expect((await store.readProjects('pi')).single.remoteId, isNull);
    server.failAssignment = false;
    await sync.synchronize();
    expect(server.projects, hasLength(1));
    expect(server.threads.single['projectId'], 'shared');
  });

  test('session change aborts before writes to another connection', () async {
    await store.writeProject(legacy);
    final stale =
        SharedProjectSync(api, store, 'pi', () => throw StateError('stale'));
    await expectLater(stale.synchronize(), throwsStateError);
    expect(server.requests.map((r) => r['method']), ['project/list']);
    expect((await store.readProjects('pi')).single.remoteId, isNull);
  });

  test('new tasks and project pagination use project identity, not just cwd',
      () async {
    await api.startThread(cwd: '/srv/app', projectId: 'shared');
    await api.readTaskPage(projectId: 'shared', cursor: 'next');
    expect(server.requests.first['params'],
        {'cwd': '/srv/app', 'projectId': 'shared'});
    expect(server.requests.last['params']['projectId'], 'shared');
    expect(server.requests.last['params']['cursor'], 'next');
    expect(server.requests.last['params'].containsKey('cwd'), isFalse);
  });
}
