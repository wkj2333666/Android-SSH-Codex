import 'dart:async';
import 'dart:io';

import 'package:android_ssh_codex/src/diagnostics.dart';
import 'package:android_ssh_codex/src/protocol/json_rpc_client.dart';
import 'package:android_ssh_codex/src/protocol/rpc_transport.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(Diagnostics.channel, null);
  });

  test('records timestamped metadata and exports with cancellation', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(Diagnostics.channel, (call) async {
      calls.add(call);
      return call.method == 'export' ? false : null;
    });
    Diagnostics.record('connection.open', {'attempt': 2});
    await Future<void>.delayed(Duration.zero);
    expect(calls.single.method, 'record');
    expect(calls.single.arguments['attempt'], 2);
    expect(DateTime.parse(calls.single.arguments['time'] as String).isUtc, true);
    expect(await Diagnostics.export(), false);
  });

  test('logging failure never escapes to connection caller', () async {
    messenger.setMockMethodCallHandler(Diagnostics.channel, (call) async {
      throw PlatformException(code: 'IO_ERROR');
    });
    Diagnostics.record('rpc.disconnected');
    await Future<void>.delayed(Duration.zero);
  });

  test('errors exclude addresses, exception text and payloads', () {
    final fields = Diagnostics.errorFields(const SocketException(
      'secret address and payload',
      osError: OSError('sensitive system message', 104),
    ));
    expect(fields, {'errorType': 'SocketException', 'osCode': 104});
    expect(Diagnostics.errorFields(const FormatException('secret', 'payload')),
        {'errorType': 'FormatException'});
  });

  test('slow native logger has bounded outstanding requests', () async {
    final blocked = Completer<void>();
    var count = 0;
    messenger.setMockMethodCallHandler(Diagnostics.channel, (call) async {
      count++;
      await blocked.future;
      return null;
    });
    for (var i = 0; i < 1000; i++) {
      Diagnostics.record('test');
    }
    await Future<void>.delayed(Duration.zero);
    expect(count, 128);
    blocked.complete();
    await Future<void>.delayed(Duration.zero);
    Diagnostics.record('after');
    await Future<void>.delayed(Duration.zero);
    expect(count, 129);
  });

  test('non-Android platforms do not invoke native logging', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    messenger.setMockMethodCallHandler(Diagnostics.channel, (call) async {
      fail('unexpected channel invocation');
    });
    Diagnostics.record('test');
    await Future<void>.delayed(Duration.zero);
  });

  test('RPC records the first stream error even without pending requests',
      () async {
    final events = <Map<dynamic, dynamic>>[];
    messenger.setMockMethodCallHandler(Diagnostics.channel, (call) async {
      events.add(call.arguments as Map<dynamic, dynamic>);
      return null;
    });
    final transport = _Transport();
    final rpc = JsonRpcClient(transport)..start();
    transport.input.addError(const SocketException(
      'private host',
      osError: OSError('private OS description', 104),
    ));
    await rpc.done;
    await rpc.close();
    await transport.input.close();
    await Future<void>.delayed(Duration.zero);
    final failures = events.where((event) => event['event'] == 'rpc.disconnected');
    expect(failures.length, 1);
    expect(failures.single['cause'], 'streamError');
    expect(failures.single['osCode'], 104);
    expect(failures.single['pendingRequests'], 0);
    expect(events.toString(), isNot(contains('private')));
  });
}

class _Transport implements RpcTransport {
  final input = StreamController<String>();

  @override
  Stream<String> get messages => input.stream;

  @override
  void send(String message) {}

  @override
  Future<void> close() async {}
}
