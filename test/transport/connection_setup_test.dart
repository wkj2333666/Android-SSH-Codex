import 'dart:async';

import 'package:android_ssh_codex/src/connection_lifecycle.dart';
import 'package:android_ssh_codex/src/transport/connection_setup.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SSH failure releases a bootstrap command that never completes',
      () async {
    final setup = ConnectionSetup(11);
    final done = Completer<void>();
    var closed = 0;
    setup.watchClosed(done.future, () => closed++);
    final result = setup.run('bootstrap', () => Completer<String>().future);
    final error = StateError('connection_aborted');
    final check = expectLater(result, throwsA(same(error)));
    done.completeError(error);
    await check;
    expect(closed, 1);
    setup.dispose();
  });

  test('EOF during setup also fails without waiting for an RPC timeout',
      () async {
    final setup = ConnectionSetup(1);
    final done = Completer<void>();
    setup.watchClosed(done.future, () {});
    final result = setup.run('refresh', () => Completer<void>().future);
    final check = expectLater(result, throwsStateError);
    done.complete();
    await check;
    setup.dispose();
  });

  testWidgets('stage deadline ends a hung operation', (tester) async {
    final setup = ConnectionSetup(1);
    final result = setup.run('bootstrap', () => Completer<void>().future);
    final check = expectLater(result, throwsA(isA<TimeoutException>()));
    await tester.pump(const Duration(seconds: 31));
    await check;
    setup.dispose();
  });

  test('foreground checks wall time even when background timer did not fire',
      () async {
    var now = DateTime.utc(2026, 10, 25, 4);
    final setup = ConnectionSetup(11, now: () => now);
    final result = setup.run('bootstrap', () => Completer<void>().future);
    final check = expectLater(result, throwsA(isA<TimeoutException>()));
    final lifecycle = ConnectionLifecycle(
      onBackground: () {},
      onForeground: () async => setup.checkDeadline(),
    );
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 20));
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await check;
    setup.dispose();
  });

  test('foreground leaves a healthy in-flight attempt alone', () async {
    final setup = ConnectionSetup(1);
    final operation = Completer<int>();
    final result = setup.run('bootstrap', () => operation.future);
    setup.checkDeadline();
    operation.complete(42);
    expect(await result, 42);
    setup.dispose();
  });

  test('cancelled socket arriving late is closed and never published',
      () async {
    final setup = ConnectionSetup(1);
    final socket = Completer<int>();
    var lateClosed = 0;
    final result = setup.run('ssh', () => socket.future,
        closeLateResult: (value) async => lateClosed += value);
    final check = expectLater(result, throwsStateError);
    setup.cancel(StateError('User disconnected'));
    await check;
    setup.dispose();
    socket.complete(1);
    await Future<void>.delayed(Duration.zero);
    expect(lateClosed, 1);
  });

  test('client created after cancellation closes immediately', () {
    final setup = ConnectionSetup(1);
    setup.cancel(StateError('Superseded'));
    var closed = 0;
    setup.watchClosed(Completer<void>().future, () => closed++);
    expect(closed, 1);
    setup.dispose();
  });

  test('a failed attempt cannot start another setup stage', () async {
    final setup = ConnectionSetup(1);
    setup.cancel(StateError('Superseded'));
    var started = false;
    await expectLater(
        setup.run('bootstrap', () async {
          started = true;
        }),
        throwsStateError);
    expect(started, isFalse);
    setup.dispose();
  });

  test('old SSH callbacks cannot abort a replacement attempt', () async {
    final old = ConnectionSetup(1);
    final done = Completer<void>();
    var oldCloses = 0;
    old.watchClosed(done.future, () => oldCloses++);
    expect(await old.run('initialize', () async => true), isTrue);
    old.dispose();
    final current = ConnectionSetup(2);
    done.completeError(StateError('Old socket failed'));
    expect(await current.run('initialize', () async => true), isTrue);
    expect(oldCloses, 0);
    current.dispose();
  });

  testWidgets('hung cleanup cannot hold up the next connection',
      (tester) async {
    var finished = false;
    final cleanup = boundedConnectionCleanup(
      'testSocket',
      () => Completer<void>().future,
    ).then((_) => finished = true);
    await tester.pump(const Duration(seconds: 4));
    await cleanup;
    expect(finished, isTrue);
  });
}
