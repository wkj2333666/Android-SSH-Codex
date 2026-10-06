import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:android_ssh_codex/src/transport/ssh_health_monitor.dart';

void main() {
  testWidgets('hung ping has a deadline and never overlaps', (tester) async {
    var pings = 0;
    var failures = 0;
    final reply = Completer<void>();
    final monitor = SshHealthMonitor(
      ping: () { pings++; return reply.future; },
      onFailure: (_) { failures++; },
      interval: const Duration(seconds: 1),
      timeout: const Duration(seconds: 2),
      grace: const Duration(seconds: 1),
    )..start();
    final first = monitor.check();
    expect(identical(first, monitor.check()), isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(pings, 1);
    expect(failures, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(await first, isFalse);
    expect(failures, 1);
    reply.complete();
    await tester.pump(const Duration(seconds: 10));
    expect(pings, 1);
    expect(failures, 1);
  });

  testWidgets('buffered reply during grace avoids a false disconnect', (tester) async {
    final reply = Completer<void>();
    var failures = 0;
    final monitor = SshHealthMonitor(ping: () => reply.future,
        onFailure: (_) { failures++; }, timeout: const Duration(seconds: 1));
    final check = monitor.check();
    await tester.pump(const Duration(seconds: 1));
    reply.complete();
    await tester.pump();
    expect(await check, isTrue);
    expect(failures, 0);
    monitor.dispose();
  });

  testWidgets('disposed session cannot fail a replacement session', (tester) async {
    final reply = Completer<void>();
    var failures = 0;
    final monitor = SshHealthMonitor(ping: () => reply.future,
        onFailure: (_) { failures++; });
    final check = monitor.check();
    monitor.dispose();
    reply.completeError(StateError('old socket'));
    await tester.pump();
    expect(await check, isFalse);
    expect(failures, 0);
  });
}
