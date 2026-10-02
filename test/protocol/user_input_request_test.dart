import 'package:android_ssh_codex/src/protocol/json_rpc_client.dart';
import 'package:android_ssh_codex/src/protocol/user_input_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('blocking and asynchronous questions use question IDs on the wire', () {
    for (final blocking in [true, false]) {
      final request = UserInputRequest(RpcServerRequest(12, 'item/tool/requestUserInput', {
        'threadId': 't', 'turnId': 'turn', 'itemId': 'item', 'isBlocking': blocking,
        'questions': [
          {'id': 'choice', 'header': 'Choice', 'question': 'Pick one', 'isOther': true,
           'options': [{'label': 'One', 'description': 'First'}]},
          {'id': 'secret', 'header': 'Secret', 'question': 'Token?', 'isSecret': true, 'options': null},
        ],
      }));
      expect(request.isBlocking, blocking);
      expect(request.questions.last.isSecret, isTrue);
      expect(request.response({'choice': 'One', 'secret': 'value'}), {
        'answers': {'choice': {'answers': ['One']}, 'secret': {'answers': ['value']}}
      });
      expect(request.response({})['answers']['choice'], {'answers': <String>[]});
    }
  });

  test('duplicate question identifiers are rejected', () {
    expect(() => UserInputRequest(RpcServerRequest('r', 'item/tool/requestUserInput', {
      'threadId': 't', 'turnId': 'turn',
      'questions': List.generate(2, (_) => {'id': 'q', 'header': 'Q', 'question': '?'}),
    })), throwsFormatException);
  });
}
