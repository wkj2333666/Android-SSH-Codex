import 'dart:async';
import 'dart:convert';

import 'package:android_ssh_codex/src/account_usage.dart';
import 'package:android_ssh_codex/src/app_controller.dart';
import 'package:android_ssh_codex/src/protocol/codex_remote_api.dart';
import 'package:android_ssh_codex/src/protocol/json_rpc_client.dart';
import 'package:android_ssh_codex/src/protocol/rpc_transport.dart';
import 'package:android_ssh_codex/src/ui/widgets/account_usage_panel.dart';
import 'package:android_ssh_codex/src/ui/turn_settings_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements RpcTransport {
  final input = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  @override
  Stream<String> get messages => input.stream;
  @override
  void send(String message) => calls.add(jsonDecode(message));
  void reply(Map<String, dynamic> result, {int? id}) =>
      input.add(jsonEncode({'id': id ?? calls.last['id'], 'result': result}));
  void notify(String method, Map<String, dynamic> params) =>
      input.add(jsonEncode({'method': method, 'params': params}));
  @override
  Future<void> close() async {
    if (!input.isClosed) await input.close();
  }
}

Map<String, dynamic> quota(num used, {String id = 'codex'}) => {
      'rateLimits': {
        'limitId': id,
        'planType': 'plus',
        'primary': {
          'usedPercent': used,
          'windowDurationMins': 300,
          'resetsAt': 1800000000,
        },
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('quota parser preserves unknown values and prefers multi-bucket data',
      () {
    final result = UsageBucket.parse({
      ...quota(99),
      'rateLimitsByLimitId': {
        'codex': {
          'primary': {'usedPercent': 25},
          'secondary': {'usedPercent': 120},
          'credits': {'balance': '42.5', 'unlimited': false},
        },
        'other': {
          'primary': {'windowDurationMins': 300},
        },
      },
    });
    expect(result.length, 2);
    expect(result['codex']!.primary!.remainingPercent, 75);
    expect(result['codex']!.primary!.minutes, isNull);
    expect(result['codex']!.secondary!.remainingPercent, 0);
    expect(result['codex']!.credits, '42.5 credits');
    expect(result['other']!.hasData, isFalse);
    expect(UsageBucket.parse({}), isEmpty);
    expect(UsageWindow.parse({'usedPercent': double.nan}), isNull);
    expect(UsageWindow.parse({'usedPercent': -2})!.remainingPercent, 100);
  });

  test('reads use empty params; pushed quotas beat an older in-flight read',
      () async {
    final transport = _Transport();
    final rpc = JsonRpcClient(transport)..start();
    final controller = AppController.connectedForTesting(rpc: rpc);
    final usage = controller.accountUsage;
    final read = usage.refresh();
    expect(transport.calls.single['method'], 'account/rateLimits/read');
    expect(transport.calls.single['params'], isEmpty);
    await usage.refresh();
    expect(transport.calls.length, 1);
    transport.notify('account/rateLimits/updated', quota(65));
    await Future<void>.delayed(Duration.zero);
    transport.reply(quota(10));
    await read;
    expect(usage.buckets.single.primary!.remainingPercent, 35);
    expect(usage.loading, isFalse);
    transport.notify('account/rateLimits/updated', quota(50, id: 'other'));
    await Future<void>.delayed(Duration.zero);
    expect(usage.buckets.length, 2);
    controller.dispose();
    await rpc.close();
  });

  test('connection/account changes discard old quotas and pending reads',
      () async {
    final transport = _Transport();
    final rpc = JsonRpcClient(transport)..start();
    final controller = AppController.connectedForTesting(rpc: rpc);
    final usage = controller.accountUsage;
    final oldRead = usage.refresh();
    usage.update(quota(30));
    transport.notify('account/updated', {'authMode': 'apikey'});
    await Future<void>.delayed(Duration.zero);
    expect(usage.buckets, isEmpty);
    expect(transport.calls.length, 2);
    transport.reply(quota(40), id: transport.calls.first['id'] as int);
    await oldRead;
    expect(usage.buckets, isEmpty);
    expect(usage.loading, isTrue);
    transport.reply({});
    await Future<void>.delayed(Duration.zero);
    expect(usage.loading, isFalse);
    final disconnectRead = usage.refresh();
    usage.bind(null);
    transport.reply(quota(50));
    await disconnectRead;
    expect(usage.online, isFalse);
    expect(usage.buckets, isEmpty);
    controller.dispose();
    await rpc.close();
  });

  testWidgets(
      'usage failure/timeout does not disconnect RPC or imply unlimited',
      (tester) async {
    final transport = _Transport();
    final rpc = JsonRpcClient(transport)..start();
    final usage = AccountUsageController()..bind(CodexRemoteApi(rpc));
    var disconnected = false;
    unawaited(rpc.done.then((_) => disconnected = true));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AccountUsagePanel(controller: usage)),
    ));
    await tester.tap(find.byTooltip('Refresh usage'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(seconds: 11));
    expect(find.textContaining('Usage unavailable'), findsOneWidget);
    expect(disconnected, isFalse);
    expect(find.textContaining('Unlimited'), findsNothing);
    await tester.tap(find.byTooltip('Refresh usage'));
    transport.reply(quota(25));
    await tester.pumpAndSettle();
    expect(find.text('5h · 75% left'), findsOneWidget);
    expect(find.textContaining('Resets '), findsOneWidget);
    expect(find.text('codex · plus'), findsOneWidget);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator))
            .value,
        0.75);
    usage.update(quota(80));
    await tester.pumpAndSettle();
    expect(find.text('5h · 20% left'), findsOneWidget);
    usage.bind(null);
    await tester.pumpAndSettle();
    expect(
        find.text('Connect to view the remote account usage.'), findsOneWidget);
    expect(find.text('5h · 20% left'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    usage.dispose();
    await tester.runAsync(rpc.close);
  });

  testWidgets('usage remains scrollable in the model panel on a small screen',
      (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final transport = _Transport();
    final rpc = JsonRpcClient(transport)..start();
    final usage = AccountUsageController()..bind(CodexRemoteApi(rpc));
    TurnSettings? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: TurnSettingsPicker(
        accountUsage: usage,
        models: const [
          RemoteModel(
            id: 'model',
            model: 'model',
            displayName: 'Model',
            description: '',
            isDefault: true,
            defaultReasoningEffort: 'high',
            supportedReasoningEfforts: [],
          ),
        ],
        value: const TurnSettings(),
        onChanged: (value) => selected = value,
      )),
    ));
    await tester.tap(find.byKey(const Key('turn-settings-selector')));
    transport.reply(quota(25));
    await tester.pumpAndSettle();
    expect(find.text('Subscription usage'), findsOneWidget);
    expect(find.text('5h · 75% left'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('turn-settings-apply')));
    await tester.tap(find.byKey(const Key('turn-settings-apply')));
    await tester.pumpAndSettle();
    expect(selected!.model, 'model');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    usage.dispose();
    await tester.runAsync(rpc.close);
  });
}
