import 'dart:async';
import 'dart:convert';

import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/ports/port_forward.dart';
import 'package:android_ssh_codex/src/profiles/profile_store.dart';
import 'package:android_ssh_codex/src/protocol/json_rpc_client.dart';
import 'package:android_ssh_codex/src/protocol/rpc_transport.dart';
import 'package:android_ssh_codex/src/ui/port_forwards_view.dart';
import 'package:android_ssh_codex/src/ui/widgets/markdown_content.dart';
import 'package:android_ssh_codex/src/ui/widgets/remote_port_link_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements RpcTransport {
  final input = StreamController<String>();
  @override
  Stream<String> get messages => input.stream;
  @override
  void send(String message) {
    final request = jsonDecode(message) as Map;
    if (request.containsKey('id')) {
      input.add(jsonEncode({'id': request['id'], 'result': {}}));
    }
  }

  @override
  Future<void> close() async {
    if (!input.isClosed) await input.close();
  }
}

void main() {
  testWidgets(
      'offline rules can be added, edited, stopped and removed without layout overflow',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final rpc = JsonRpcClient(_Transport())..start();
    final controller = AppController.connectedForTesting(rpc: rpc);
    await controller.disconnect();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PortForwardsPanel(
                controller: controller, hostId: 'test', hostLabel: 'Test'))));
    await tester.tap(find.byKey(const Key('ports-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('port-remote-port')), '3000');
    await tester.enterText(find.byKey(const Key('port-label')), 'Dev');
    await tester.tap(find.byKey(const Key('port-save')));
    await tester.pumpAndSettle();
    final rule = controller.portForwards.rules.single;
    expect(find.text('Waiting for SSH'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('port-toggle-${rule.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Stopped'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('port-actions-${rule.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit ports'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('port-remote-port')), '4000');
    await tester.enterText(find.byKey(const Key('port-local-port')), '4001');
    await tester.tap(find.byKey(const Key('port-save')));
    await tester.pumpAndSettle();
    expect(controller.portForwards.rules.single.remotePort, 4000);
    expect(controller.portForwards.rules.single.localPort, 4001);
    expect(controller.portForwards.rules.single.enabled, isFalse);
    await tester.tap(find.byKey(ValueKey('port-actions-${rule.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove rule'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(controller.portForwards.rules, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await rpc.close();
  });

  testWidgets(
      'remote localhost link requires confirmation; cancellation starts nothing',
      (tester) async {
    final rpc = JsonRpcClient(_Transport())..start();
    final controller = AppController.connectedForTesting(rpc: rpc);
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => openRemotePortLink(
                            context,
                            controller,
                            Uri.parse(
                                'http://localhost:3000/path?token=private'),
                            (_) async {
                          opened++;
                          return true;
                        }),
                    child: const Text('Visit'))))));
    await tester.tap(find.text('Visit'));
    await tester.pumpAndSettle();
    expect(find.text('Forward remote port?'), findsOneWidget);
    expect(opened, 0);
    expect(controller.portForwards.rules, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.portForwards.rules, isEmpty);
    controller.dispose();
    await rpc.close();
  });

  testWidgets('enabled matching rule is reused and browser path/query survive',
      (tester) async {
    final rpc = JsonRpcClient(_Transport())..start();
    final controller = AppController.connectedForTesting(rpc: rpc);
    final rule = PortForwardRule(
        id: 'dev', hostId: 'test', remoteHost: 'localhost', remotePort: 3000);
    await controller.portForwards.attach(
        'test', (_, __) => throw StateError('No browser TCP in this test'));
    await controller.savePortForward(rule);
    Uri? opened;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => openRemotePortLink(context, controller,
                            Uri.parse('http://localhost:3000/path?q=x#anchor'),
                            (uri) async {
                          opened = uri;
                          return true;
                        }),
                    child: const Text('Visit'))))));
    await tester.tap(find.text('Visit'));
    await tester.pumpAndSettle();
    expect(find.text('Forward remote port?'), findsNothing);
    expect(opened!.port, controller.portForwards.stateFor('dev').localPort);
    expect(opened!.path, '/path');
    expect(opened!.query, 'q=x');
    expect(opened!.fragment, 'anchor');
    expect(controller.portForwards.rules.length, 1);
    controller.dispose();
    await rpc.close();
  });

  testWidgets(
      'Markdown loopback links use SSH hook; public URLs remain external',
      (tester) async {
    final forwarded = <Uri>[];
    final external = <Uri>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: RemotePortLinkScope(
      onOpen: (_, uri, __) async {
        forwarded.add(uri);
      },
      child: MarkdownContent(
          text: '[Dev](http://localhost:3000/) [Web](https://example.com/)',
          openExternalLink: (uri) async {
            external.add(uri);
            return true;
          }),
    ))));
    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    markdown.onTapLink!('Dev', 'http://localhost:3000/', '');
    markdown.onTapLink!('Web', 'https://example.com/', '');
    await tester.pumpAndSettle();
    expect(forwarded.single.port, 3000);
    expect(external.single.host, 'example.com');
  });

  test(
      'rules persist per host across disconnect/recreation, including disabled intent',
      () async {
    final store = MemoryProfileStore();
    final rpc = JsonRpcClient(_Transport())..start();
    final controller =
        AppController.connectedForTesting(rpc: rpc, store: store);
    await controller.savePortForward(PortForwardRule(
        id: 'saved',
        hostId: 'test',
        remoteHost: 'localhost',
        remotePort: 8080,
        localPort: 9000,
        enabled: false));
    await controller.disconnect();
    await controller.flushWorkspace();
    controller.dispose();
    final nextRpc = JsonRpcClient(_Transport())..start();
    final next = AppController.connectedForTesting(rpc: nextRpc, store: store);
    await next.initialize();
    final restored = next.portForwards.forHost('test').single;
    expect(restored.localPort, 9000);
    expect(restored.enabled, isFalse);
    expect(next.portForwards.forHost('other'), isEmpty);
    expect(next.portForwards.stateFor(restored.id).localPort, isNull);
    next.dispose();
    await nextRpc.close();
  });
}
