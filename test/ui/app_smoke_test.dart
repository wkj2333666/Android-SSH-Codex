import 'package:android_ssh_codex/src/app.dart';
import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/profiles/host_profile.dart';
import 'package:flutter/material.dart' show Size;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('first launch shows the host workspace and add action', (
    tester,
  ) async {
    final controller = AppController.memory();

    await tester.pumpWidget(AndroidSshCodexApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Hosts'), findsOneWidget);
    expect(find.text('Add host'), findsOneWidget);
    expect(find.text('Remote Codex'), findsOneWidget);
  });

  testWidgets('a selected disconnected host exposes a reconnect action', (
    tester,
  ) async {
    final controller = AppController.memory();
    await controller.saveProfile(
      HostProfile(
        id: 'lab',
        label: 'Lab',
        hostName: 'lab.example',
        user: 'codex',
        port: 22,
      ),
      const HostSecret(password: 'secret'),
    );

    await tester.pumpWidget(AndroidSshCodexApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Reconnect Lab'), findsOneWidget);
  });

  for (final size in [const Size(360, 800), const Size(1200, 800)]) {
    testWidgets('workspace has no layout exception at ${size.width}px', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        AndroidSshCodexApp(controller: AppController.memory()),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  }
}
