import 'dart:async';
import 'dart:convert';

import 'package:android_ssh_codex/src/protocol/json_rpc_client.dart';
import 'package:android_ssh_codex/src/protocol/rpc_transport.dart';
import 'package:flutter_test/flutter_test.dart';

final class FakeTransport implements RpcTransport {
  final incoming = StreamController<String>();
  final sent = <String>[];
  var closeCalls = 0;

  @override
  Stream<String> get messages => incoming.stream;

  @override
  void send(String message) => sent.add(message);

  @override
  Future<void> close() async {
    closeCalls++;
    if (!incoming.isClosed) await incoming.close();
  }
}

void main() {
  late FakeTransport transport;
  late JsonRpcClient client;

  setUp(() {
    transport = FakeTransport();
    client = JsonRpcClient(transport)..start();
  });

  tearDown(() => client.close());

  test('correlates a response with its request id', () async {
    final response = client.request('thread/list', {'limit': 20});
    final request = jsonDecode(transport.sent.single) as Map<String, dynamic>;
    transport.incoming.add(jsonEncode({
      'id': request['id'],
      'result': {'data': []},
    }));

    expect(await response, {'data': []});
  });

  test('throws a typed remote error', () async {
    final response = client.request('thread/read', {'threadId': 'missing'});
    final request = jsonDecode(transport.sent.single) as Map<String, dynamic>;
    transport.incoming.add(jsonEncode({
      'id': request['id'],
      'error': {'code': -32000, 'message': 'not found'},
    }));

    await expectLater(
      response,
      throwsA(isA<RpcRemoteException>()
          .having((error) => error.code, 'code', -32000)),
    );
  });

  test('emits notifications that have no id', () async {
    final notification = client.notifications.first;
    transport.incoming.add(jsonEncode({
      'method': 'turn/completed',
      'params': {'threadId': 'one'},
    }));

    expect((await notification).method, 'turn/completed');
  });

  test('emits server requests and can answer the original id', () async {
    final pending = client.serverRequests.first;
    transport.incoming.add(jsonEncode({
      'id': 91,
      'method': 'item/commandExecution/requestApproval',
      'params': {'threadId': 'one', 'itemId': 'cmd'},
    }));
    final request = await pending;

    client.respond(request.id, {'decision': 'accept'});

    expect(jsonDecode(transport.sent.single), {
      'id': 91,
      'result': {'decision': 'accept'},
    });
  });

  test('fails pending requests when the transport closes', () async {
    final response = client.request('model/list');
    await transport.incoming.close();

    await expectLater(response, throwsA(isA<RpcDisconnectedException>()));
  });

  test('a timed out request leaves the transport usable', () async {
    await client.close();
    transport = FakeTransport();
    client = JsonRpcClient(
      transport,
      requestTimeout: const Duration(milliseconds: 10),
    )..start();

    final response = client.request('thread/turns/list', {'threadId': 'one'});

    await expectLater(
      response,
      throwsA(
        isA<RpcTimeoutException>()
            .having((error) => error.method, 'method', 'thread/turns/list'),
      ),
    );

    expect(transport.closeCalls, 0);
    final nextResponse = client.request('model/list');
    final nextRequest = jsonDecode(transport.sent.last) as Map<String, dynamic>;
    transport.incoming.add(jsonEncode({
      'id': nextRequest['id'],
      'result': {'data': []},
    }));

    expect(await nextResponse, {'data': []});
    expect(transport.closeCalls, 0);
  });

  test('closes public event streams when the transport disconnects', () async {
    final notificationsDone = client.notifications.drain<void>();
    final requestsDone = client.serverRequests.drain<void>();

    await transport.incoming.close();

    await notificationsDone.timeout(const Duration(seconds: 1));
    await requestsDone.timeout(const Duration(seconds: 1));
  });

  test('close still releases transport after a remote disconnect', () async {
    await transport.incoming.close();
    await client.close();

    expect(transport.closeCalls, 1);
  });
}
