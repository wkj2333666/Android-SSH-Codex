import 'package:android_ssh_codex/src/connection_network.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('coalesces handover and ignores capability noise', (tester) async {
    final changes = <bool>[];
    final monitor = ConnectionNetwork((value) async { changes.add(value); });
    monitor.accept({'networkPresent': false});
    monitor.accept({'networkPresent': true, 'activeNetwork': 2});
    await tester.pump(const Duration(milliseconds: 500));
    expect(changes, [true]);
    monitor.accept({'networkPresent': true, 'activeNetwork': 2, 'metered': true});
    await tester.pump(const Duration(seconds: 1));
    expect(changes, [true]);
    monitor.accept({'networkPresent': true, 'activeNetwork': 2, 'blocked': true});
    await tester.pump(const Duration(milliseconds: 500));
    expect(changes, [true, false]);
    monitor.accept({'networkPresent': true, 'activeNetwork': 2, 'blocked': false});
    await tester.pump(const Duration(milliseconds: 500));
    expect(changes, [true, false, true]);
    monitor.dispose();
  });

  testWidgets('disposed monitor cannot trigger a reconnect', (tester) async {
    var calls = 0;
    final monitor = ConnectionNetwork((_) async { calls++; });
    monitor.accept({'networkPresent': true, 'activeNetwork': 1});
    monitor.dispose();
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 0);
  });
}
