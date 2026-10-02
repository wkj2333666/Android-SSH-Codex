import 'json_rpc_client.dart';

class UserInputQuestion {
  UserInputQuestion(Map<String, dynamic> value)
      : id = value['id'] as String,
        header = value['header'] as String,
        question = value['question'] as String,
        isOther = value['isOther'] == true,
        isSecret = value['isSecret'] == true,
        options = [
          for (final option in value['options'] as List? ?? const [])
            (label: option['label'] as String,
             description: option['description'] as String? ?? ''),
        ];

  final String id, header, question;
  final bool isOther, isSecret;
  final List<({String label, String description})> options;
}

class UserInputRequest {
  UserInputRequest(RpcServerRequest request)
      : id = request.id,
        threadId = request.params['threadId'] as String,
        turnId = request.params['turnId'] as String,
        isBlocking = request.params['isBlocking'] != false,
        questions = [
          for (final raw in request.params['questions'] as List)
            UserInputQuestion(Map<String, dynamic>.from(raw as Map)),
        ] {
    if (questions.isEmpty || questions.length > 20 ||
        questions.any((q) => q.id.isEmpty) ||
        questions.map((q) => q.id).toSet().length != questions.length) {
      throw const FormatException('Invalid user input questions');
    }
  }

  final Object id;
  final String threadId, turnId;
  final bool isBlocking;
  final List<UserInputQuestion> questions;

  Map<String, dynamic> response(Map<String, String> answers) => {
        'answers': {
          for (final question in questions)
            question.id: {
              'answers': [
                if (answers[question.id]?.trim().isNotEmpty == true)
                  answers[question.id]!,
              ],
            },
        },
      };
}
