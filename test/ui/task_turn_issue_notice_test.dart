import 'package:android_ssh_codex/src/tasks/task_turn_issue.dart';
import 'package:android_ssh_codex/src/ui/widgets/task_turn_issue_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const issue = TaskTurnIssue(
    turnId: 'failed',
    message: 'Codex reply failed',
    code: 'serverOverloaded',
    details: 'No reply was generated.',
  );

  testWidgets('live error opens once and remains available after closing',
      (tester) async {
    var pending = true;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TaskTurnIssueNotice(
          issue: issue,
          autoShow: true,
          takePopup: () {
            final available = pending;
            pending = false;
            return available;
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('Code: serverOverloaded'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Codex reply failed'), findsOneWidget);
    await tester.tap(find.text('Codex reply failed'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('historical error is visible without an automatic dialog',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TaskTurnIssueNotice(
          issue: issue,
          autoShow: false,
          takePopup: () => false,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Codex reply failed'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
