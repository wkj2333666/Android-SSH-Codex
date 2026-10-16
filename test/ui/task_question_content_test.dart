import 'package:android_ssh_codex/src/tasks/task_reducer.dart';
import 'package:android_ssh_codex/src/ui/widgets/task_question_content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const questions = [
    TaskQuestion(title: '扬声器接在哪里？', options: ['主板 3.5 mm 音箱', 'HDMI'])
  ];
  const fallback = '扬声器接在哪里？\n\n- 主板 3.5 mm 音箱\n- HDMI';

  test('complete fallback is omitted, surrounding prose is retained', () {
    expect(questionMessageBody(fallback, questions), '');
    expect(questionMessageBody('说明\n\n$fallback\n\n补充说明', questions),
        '说明\n\n\n补充说明');
    expect(questionMessageBody(fallback, const []), fallback);
  });

  test('formatted titles and numbered options are recognized', () {
    expect(
        questionMessageBody(
            '## **扬声器接在哪里？**\n\n1. 主板 3.5 mm 音箱\n2. HDMI', questions),
        '');
  });

  test('partial or different content is never removed', () {
    const partial = '扬声器接在哪里？\n\n- 主板 3.5 mm 音箱';
    const different = '扬声器接在哪里？\n\n- 主板 3.5 mm 音箱\n- USB';
    expect(questionMessageBody(partial, questions), partial);
    expect(questionMessageBody(different, questions), different);
  });

  test('fenced and indented code remain visible', () {
    const fenced = '```text\n$fallback\n```';
    const indented = '    扬声器接在哪里？\n    - 主板 3.5 mm 音箱\n    - HDMI';
    expect(questionMessageBody(fenced, questions), fenced);
    expect(questionMessageBody(indented, questions), indented.trim());
  });

  test('multiple questions and soft-wrapped titles are deduplicated', () {
    const items = [
      TaskQuestion(title: 'Which environment?', options: ['Staging']),
      TaskQuestion(title: 'Other details?'),
    ];
    expect(
        questionMessageBody(
            'Which\nenvironment?\n- Staging\n\nOther details?', items),
        '');
  });
}
