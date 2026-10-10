import 'package:android_ssh_codex/src/app.dart';
import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/profiles/host_profile.dart';
import 'package:android_ssh_codex/src/diagnostics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('first launch shows the host workspace and add action', (
    tester,
  ) async {
    final controller = AppController.memory();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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

    expect(find.byTooltip('Reconnect Lab'), findsOneWidget);
  });

  for (final size in [const Size(360, 800), const Size(1200, 800), const Size(1000, 400)]) {
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
      if (size.width >= 800) {
        expect(tester.getSize(find.byKey(const Key('compact-navigation'))).width, 72);
        await tester.tap(find.byTooltip('Tasks'));
        await tester.pumpAndSettle();
        expect(find.text('Workspace'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('clear diagnostics requires confirmation and preserves hosts', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(Diagnostics.channel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(Diagnostics.channel, null);
    });
    final controller = AppController.memory();
    await controller.saveProfile(HostProfile(id: 'lab', label: 'Lab',
      hostName: 'lab.example', user: 'user', port: 22), const HostSecret());
    await tester.pumpWidget(AndroidSshCodexApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Connection diagnostics'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear connection logs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls, isNot(contains('clear')));
    await tester.tap(find.byTooltip('Connection diagnostics'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear connection logs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear logs'));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call == 'clear'), hasLength(1));
    expect(find.text('Connection logs cleared'), findsOneWidget);
    expect(controller.profiles.single.id, 'lab');
    messenger.setMockMethodCallHandler(Diagnostics.channel, (_) async {
      throw PlatformException(code: 'CLEAR_FAILED');
    });
    await tester.tap(find.byTooltip('Connection diagnostics'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear connection logs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear logs'));
    await tester.pumpAndSettle();
    expect(find.text('Could not clear logs. Try again.'), findsOneWidget);
  });

  testWidgets('narrow host cards keep long names above their actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const label = 'Raspberry Pi development environment';
    final controller = AppController.memory();
    await controller.saveProfile(
      HostProfile(
        id: 'pi',
        label: label,
        hostName: '192.0.2.10',
        user: 'codex',
        port: 22,
      ),
      const HostSecret(password: 'secret'),
    );

    await tester.pumpWidget(AndroidSshCodexApp(controller: controller));
    await tester.pumpAndSettle();

    final title = tester.widget<Text>(find.text(label));
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(
      tester.getTopLeft(find.text('Connect')).dy,
      greaterThan(tester.getBottomLeft(find.text(label)).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('host cards identify independently configured app-server modes',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController.memory();
    await controller.saveProfile(
      HostProfile(
        id: 'shared',
        label: 'Shared Pi',
        hostName: '192.0.2.10',
        user: 'codex',
        port: 22,
        appServerMode: AppServerMode.shared,
      ),
      const HostSecret(password: 'secret'),
    );
    await controller.saveProfile(
      HostProfile(
        id: 'isolated',
        label: 'Isolated Pi',
        hostName: '192.0.2.10',
        user: 'codex',
        port: 22,
        appServerMode: AppServerMode.isolated,
      ),
      const HostSecret(password: 'secret'),
    );

    await tester.pumpWidget(AndroidSshCodexApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Shared app-server'), findsOneWidget);
    expect(find.text('Isolated app-server'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
