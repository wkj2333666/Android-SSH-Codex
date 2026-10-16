import 'package:android_ssh_codex/src/tasks/task_reducer.dart';
import 'package:android_ssh_codex/src/ui/task_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const items = [TaskItem(id: 'cached', kind: TaskItemKind.agent, text: 'Cached answer')];

  testWidgets('refresh progress does not hide cached conversation', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
      body: TaskTimeline(items: items, loading: true),
    )));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('refresh error is visible alongside cache and can retry', (tester) async {
    var retries = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: TaskTimeline(items: items, error: 'Latest read failed', onRetry: () => retries++),
    )));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('task-refresh-error')), findsOneWidget);
    expect(find.textContaining('Latest read failed'), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retries, 1);
  });
}
