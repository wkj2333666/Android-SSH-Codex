import 'package:android_ssh_codex/src/tasks/task_reducer.dart';
import 'package:android_ssh_codex/src/ui/timeline_entries.dart';
import 'package:android_ssh_codex/src/ui/widgets/codex_directive_content.dart';
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

  testWidgets('Markdown links open only safe web URLs', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MarkdownContent(
          text: '[OpenAI](https://openai.com) [unsafe](javascript:alert(1))',
          openExternalLink: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
      ),
    ));

    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    markdown.onTapLink!('OpenAI', 'https://openai.com', '');
    await tester.pump();
    expect(opened, [Uri.parse('https://openai.com')]);

    markdown.onTapLink!('unsafe', 'javascript:alert(1)', '');
    await tester.pump();
    expect(opened, [Uri.parse('https://openai.com')]);
    expect(
      find.text('Only HTTP and HTTPS links can be opened.'),
      findsOneWidget,
    );
  });

  test('recognized Git directives are extracted from agent text', () {
    final parsed = parseCodexDirectiveContent(
      'Done. '
      '::git-create-branch{cwd="/repo" branch="codex/fix"} '
      '::git-commit{cwd="/repo"} '
      '::git-push{cwd="/repo" branch="codex/fix"} '
      '::git-create-pr{cwd="/repo" branch="codex/fix" '
      'url="https://github.com/example/repo/pull/7" isDraft=false}',
    );

    expect(parsed.markdown, 'Done.');
    expect(
      parsed.directives.map((directive) => directive.name),
      [
        'git-create-branch',
        'git-commit',
        'git-push',
        'git-create-pr',
      ],
    );
    expect(parsed.directives.last.branch, 'codex/fix');
    expect(
      parsed.directives.last.webUri,
      Uri.parse('https://github.com/example/repo/pull/7'),
    );
  });

  test('unknown directives remain literal and unsafe PR links are inert', () {
    final parsed = parseCodexDirectiveContent(
      '::unknown{name="keep me"} '
      '::git-create-pr{url="file:///tmp/private" isDraft=true}',
    );

    expect(parsed.markdown, '::unknown{name="keep me"}');
    expect(parsed.directives, hasLength(1));
    expect(parsed.directives.single.webUri, isNull);
  });

  testWidgets('agent Git directives render as a compact card without raw text',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TimelineItemView(
          item: TaskItem(
            id: 'agent-git',
            kind: TaskItemKind.agent,
            text: 'Published. '
                '::git-create-branch{cwd="/repo" branch="codex/fix"} '
                '::git-push{cwd="/repo" branch="codex/fix"} '
                '::git-create-pr{cwd="/repo" branch="codex/fix" '
                'url="https://github.com/example/repo/pull/7" isDraft=false}',
          ),
        ),
      ),
    ));

    expect(find.text('Published.'), findsOneWidget);
    expect(find.textContaining('::git-'), findsNothing);
    expect(find.byKey(const Key('git-activity-card')), findsOneWidget);
    expect(find.text('Branch created'), findsOneWidget);
    expect(find.text('Pushed'), findsOneWidget);
    expect(find.text('Pull request'), findsOneWidget);
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
