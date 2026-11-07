import 'package:android_ssh_codex/src/ui/permission_picker.dart';
import 'package:android_ssh_codex/src/tasks/permission_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('full access requires confirmation and cancel preserves intent', (tester) async {
    PermissionMode? chosen;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PermissionPicker(
      value: PermissionMode.inherit, onChanged: (value) => chosen = value))));
    await tester.tap(find.byKey(const Key('permission-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('permission-fullAccess')));
    await tester.pumpAndSettle();
    expect(find.text('Allow full access?'), findsOneWidget);
    expect(chosen, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(chosen, isNull);
    await tester.tap(find.byKey(const Key('permission-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('permission-workspace')));
    await tester.pumpAndSettle();
    expect(chosen, PermissionMode.workspace);
  });
}
