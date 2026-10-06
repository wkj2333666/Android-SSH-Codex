import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/connection_lifecycle.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one foreground recovery per background transition', () async {
    var backgrounds = 0;
    var recoveries = 0;
    final lifecycle = ConnectionLifecycle(
      onBackground: () => backgrounds++,
      onForeground: () async => recoveries++,
    );
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.hidden);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.detached);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.inactive);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(backgrounds, 1);
    expect(recoveries, 1);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(backgrounds, 2);
    expect(recoveries, 2);
  });

  test('focus changes and initial resume do not trigger recovery', () {
    var calls = 0;
    final lifecycle = ConnectionLifecycle(
      onBackground: () => calls++,
      onForeground: () async => calls++,
    );
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.inactive);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(calls, 0);
  });

  test('foregrounding respects an explicitly disconnected controller',
      () async {
    final controller = AppController.memory();
    await controller.disconnect();
    controller.enterBackground();
    await controller.restoreForegroundConnection();
    expect(controller.connectionPhase, RemoteConnectionPhase.disconnected);
    controller.dispose();
  });
}
