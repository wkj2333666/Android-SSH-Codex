import 'dart:async';
import 'dart:io';

import 'package:android_ssh_codex/src/diagnostics.dart';
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
}
