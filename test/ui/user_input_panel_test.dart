import 'package:android_ssh_codex/src/protocol/json_rpc_client.dart';
import 'package:android_ssh_codex/src/protocol/user_input_request.dart';
import 'package:android_ssh_codex/src/ui/widgets/user_input_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

void main() {
  testWidgets('no automatic answer; user can select or type a custom answer',
      (tester) async {
    Map<String, String>? submitted;
    final request = UserInputRequest(
        const RpcServerRequest('r', 'item/tool/requestUserInput', {
      'threadId': 't',
      'turnId': 'turn',
      'isBlocking': false,
      'questions': [
        {
          'id': 'q',
          'header': 'Choice',
          'question': '**Which?**',
          'isOther': true,
          'options': [
            {'label': 'First', 'description': '**Recommended**'}
          ]
        }
      ],
    }));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: UserInputPanel(
      request: request,
      onAnswer: (answers) => submitted = answers,
    ))));
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    expect(find.byType(MarkdownBody), findsNWidgets(3));
    expect(find.text('**Which?**'), findsNothing);
    expect(find.textContaining('Which?', findRichText: true), findsOneWidget);
    await tester.tap(find.text('First', findRichText: true));
    await tester.pump();
    await tester.tap(find.text('Submit answers'));
    expect(submitted, {'q': 'First'});
    await tester.enterText(find.byType(TextField), 'My choice');
    await tester.pump();
    await tester.tap(find.text('Submit answers'));
    expect(submitted, {'q': 'My choice'});
    await tester.tap(find.text('Skip'));
    expect(submitted, isEmpty);
  });
}
