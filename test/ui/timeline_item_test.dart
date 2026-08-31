import 'package:android_ssh_codex/src/tasks/task_reducer.dart';
import 'package:android_ssh_codex/src/ui/timeline_entries.dart';
import 'package:android_ssh_codex/src/ui/widgets/markdown_content.dart';
import 'package:android_ssh_codex/src/ui/widgets/timeline_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('contiguous work events collapse between standalone messages', () {
    const user = TaskItem(
      id: 'user',
      kind: TaskItemKind.user,
      text: 'Please inspect this',
    );
    const command = TaskItem(
      id: 'command',
      kind: TaskItemKind.command,
      text: 'rg TODO',
    );
    const reasoning = TaskItem(
      id: 'reasoning',
      kind: TaskItemKind.reasoning,
      text: 'Checking matches',
    );
    const tool = TaskItem(
      id: 'tool',
      kind: TaskItemKind.tool,
      text: 'Read issue',
    );
    const agent = TaskItem(
      id: 'agent',
      kind: TaskItemKind.agent,
      text: 'I found the cause.',
    );

    final entries = buildTimelineEntries([
      user,
      command,
      reasoning,
      tool,
      agent,
    ]);

    expect(entries, hasLength(3));
    expect((entries[0] as TimelineMessageEntry).item, same(user));
    expect(
      (entries[1] as TimelineActivityEntry).items,
      [command, reasoning, tool],
    );
    expect((entries[2] as TimelineMessageEntry).item, same(agent));
  });

  testWidgets('work details use one compact collapsed box', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TimelineActivityGroup(
          items: [
            TaskItem(
              id: 'command',
              kind: TaskItemKind.command,
              title: 'rg TODO',
              text: '/repo',
              detail: 'two matches',
            ),
            TaskItem(
              id: 'reasoning',
              kind: TaskItemKind.reasoning,
              title: 'Reasoning',
              text: 'Checking matches',
            ),
            TaskItem(
              id: 'tool',
              kind: TaskItemKind.tool,
              title: 'github · get_issue',
              text: 'get_issue',
            ),
          ],
        ),
      ),
    ));

    expect(find.byKey(const Key('activity-group')), findsOneWidget);
    expect(find.text('3 work events'), findsOneWidget);
    expect(find.text('rg TODO'), findsNothing);
    expect(find.text('Checking matches'), findsNothing);

    await tester.tap(find.text('3 work events'));
    await tester.pumpAndSettle();

    expect(find.text('rg TODO'), findsOneWidget);
    expect(find.text('Checking matches'), findsOneWidget);
    expect(find.text('github · get_issue'), findsOneWidget);
  });

  testWidgets('model replies render selectable Markdown and LaTeX',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MarkdownContent(
          text: '**Result** with `code` and \$x^2 + y^2 = z^2\$',
        ),
      ),
    ));

    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(markdown.selectable, isTrue);
    expect(markdown.builders, contains('latex'));
    expect(markdown.imageBuilder, isNotNull);
    expect(find.textContaining('Result', findRichText: true), findsOneWidget);
  });

  testWidgets('a sending user message shows compact progress', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TimelineItemView(
          item: TaskItem(
            id: 'pending-user',
            kind: TaskItemKind.user,
            text: 'Continue the task',
            status: 'sending',
          ),
        ),
      ),
    ));

    expect(find.text('Continue the task'), findsOneWidget);
    expect(find.byKey(const Key('pending-user-progress')), findsOneWidget);
  });

  testWidgets('reasoning is collapsed until explicitly expanded',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TimelineItemView(
          item: TaskItem(
            id: 'reasoning-1',
            kind: TaskItemKind.reasoning,
            title: 'Reasoning',
            text: 'Inspecting the dependency graph',
          ),
        ),
      ),
    ));

    expect(find.text('Reasoning'), findsOneWidget);
    expect(find.text('Inspecting the dependency graph'), findsNothing);

    await tester.tap(find.text('Reasoning'));
    await tester.pumpAndSettle();

    expect(find.text('Inspecting the dependency graph'), findsOneWidget);
  });

  testWidgets('single-line display formulas render without dollar delimiters',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: MarkdownContent(text: r'$$x^2 + y^2 = z^2$$')),
    ));

    expect(find.text('x^2 + y^2 = z^2'), findsOneWidget);
    expect(find.text(r'$$x^2 + y^2 = z^2$$'), findsNothing);
  });

  testWidgets('tool card separates identity, status, and verbose detail',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TimelineItemView(
          item: TaskItem(
            id: 'tool-1',
            kind: TaskItemKind.tool,
            title: 'github · create_issue',
            text: 'Create issue',
            detail: '{"repository":"example/repo"}',
            status: 'completed',
          ),
        ),
      ),
    ));

    expect(find.text('github · create_issue'), findsOneWidget);
    expect(find.text('completed'), findsOneWidget);
    expect(find.text('{"repository":"example/repo"}'), findsNothing);

    await tester.tap(find.text('github · create_issue'));
    await tester.pumpAndSettle();

    expect(find.text('{"repository":"example/repo"}'), findsOneWidget);
  });
}
