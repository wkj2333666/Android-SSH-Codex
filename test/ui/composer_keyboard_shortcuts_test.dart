import 'package:android_ssh_codex/src/ui/widgets/composer_keyboard_shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _mountComposer(
  WidgetTester tester,
  TextEditingController controller,
  VoidCallback? onSend,
) async {
  addTearDown(controller.dispose);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ComposerKeyboardShortcuts(
        controller: controller,
        onSend: onSend,
        child: TextField(
          controller: controller,
          maxLines: 5,
          textInputAction: TextInputAction.newline,
        ),
      ),
    ),
  ));
  await tester.showKeyboard(find.byType(TextField));
  await tester.pump();
}

void main() {
  testWidgets('physical Enter sends once even when held', (tester) async {
    final controller = TextEditingController(text: 'Ready');
    final sent = <String>[];
    await _mountComposer(tester, controller, () => sent.add(controller.text));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter,
        platform: 'android');
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter,
        platform: 'android');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter, platform: 'android');

    expect(sent, ['Ready']);
    expect(controller.text, 'Ready');
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter,
        platform: 'android');
    expect(sent, ['Ready', 'Ready']);
  });

  testWidgets('Ctrl+Enter replaces selection with a newline', (tester) async {
    final controller = TextEditingController(text: 'first | last');
    var sends = 0;
    await _mountComposer(tester, controller, () => sends++);
    controller.selection = const TextSelection(baseOffset: 8, extentOffset: 5);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft,
        platform: 'android');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter, platform: 'android');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft,
        platform: 'android');

    expect(controller.text, 'first\nlast');
    expect(controller.selection, const TextSelection.collapsed(offset: 6));
    expect(sends, 0);
  });

  testWidgets('software newline and composing Enter do not submit',
      (tester) async {
    final controller = TextEditingController();
    var sends = 0;
    await _mountComposer(tester, controller, () => sends++);

    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: 'first\n',
      selection: TextSelection.collapsed(offset: 6),
    ));
    await tester.testTextInput.receiveAction(TextInputAction.newline);
    await tester.pump();
    expect(controller.text, 'first\n');
    expect(sends, 0);

    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: 'first\nni',
      selection: TextSelection.collapsed(offset: 8),
      composing: TextRange(start: 6, end: 8),
    ));
    await tester.pump();
    expect(controller.value.composing, const TextRange(start: 6, end: 8));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter, platform: 'android');
    expect(sends, 0);
  });

  testWidgets('IME-originated logical Enter falls through', (tester) async {
    final controller = TextEditingController(text: 'Draft');
    var sends = 0;
    await _mountComposer(tester, controller, () => sends++);
    final focus = tester.widget<Focus>(find.descendant(
      of: find.byType(ComposerKeyboardShortcuts),
      matching: find.byWidgetPredicate(
          (widget) => widget is Focus && widget.onKeyEvent != null),
    ).first);
    final result = focus.onKeyEvent!(
      FocusManager.instance.primaryFocus!,
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey(0x01100000042),
        logicalKey: LogicalKeyboardKey.enter,
        timeStamp: Duration.zero,
      ),
    );
    expect(result, KeyEventResult.ignored);
    expect(sends, 0);
  });
}
