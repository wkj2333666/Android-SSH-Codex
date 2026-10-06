import 'dart:async';

import 'package:android_ssh_codex/src/connection_keep_alive.dart';
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
    messenger.setMockMethodCallHandler(ConnectionKeepAlive.channel, null);
  });

  test('slow start is followed by stop, without duplicate native starts',
      () async {
    final started = Completer<bool>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(ConnectionKeepAlive.channel, (call) {
      calls.add(call.method);
      return call.method == 'start' ? started.future : Future.value(true);
    });
    final service = ConnectionKeepAlive();
    final start = service.setEnabled(true);
    final duplicate = service.setEnabled(true);
    final stop = service.setEnabled(false);
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['start']);
    started.complete(true);
    await Future.wait([start, duplicate, stop]);
    expect(calls, ['start', 'stop']);
  });

  test('notification denial warns but still stops the running service',
      () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(ConnectionKeepAlive.channel,
        (call) async {
      calls.add(call.method);
      return false;
    });
    final service = ConnectionKeepAlive();
    await expectLater(service.setEnabled(true), throwsStateError);
    await service.setEnabled(false);
    expect(calls, ['start', 'stop']);
  });

  test('switching back to a connection after stop leaves protection active',
      () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(ConnectionKeepAlive.channel,
        (call) async {
      calls.add(call.method);
      return true;
    });
    final service = ConnectionKeepAlive();
    await Future.wait([
      service.setEnabled(true),
      service.setEnabled(false),
      service.setEnabled(true),
    ]);
    expect(calls, ['start', 'stop', 'start']);
    expect(service.isEnabled, isTrue);
  });

  test('failed native start may be retried', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(ConnectionKeepAlive.channel, (_) async {
      if (++calls == 1) throw PlatformException(code: 'START_DENIED');
      return true;
    });
    final service = ConnectionKeepAlive();
    await expectLater(
        service.setEnabled(true), throwsA(isA<PlatformException>()));
    await service.setEnabled(true);
    expect(calls, 2);
  });

  test('non-Android platforms never call the native channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    messenger.setMockMethodCallHandler(ConnectionKeepAlive.channel, (_) async {
      fail('Unexpected native call');
    });
    final service = ConnectionKeepAlive();
    await service.setEnabled(true);
    await service.setEnabled(false);
  });

  test('foreground verification restarts an unexpectedly stopped service',
      () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(ConnectionKeepAlive.channel,
        (call) async {
      calls.add(call.method);
      return call.method != 'status';
    });
    final service = ConnectionKeepAlive();
    await service.setEnabled(true);
    await service.setEnabled(true, verifyNative: true);
    expect(calls, ['start', 'status', 'start']);
    expect(service.isEnabled, isTrue);
  });
}
