import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Hardware-only shortcuts scoped to the composer. Software IME edits still
/// go straight to the multiline text field.
class ComposerKeyboardShortcuts extends StatelessWidget {
  const ComposerKeyboardShortcuts({
    required this.controller,
    required this.onSend,
    required this.child,
    this.onAcceptPrediction,
    super.key,
  });

  final TextEditingController controller;
  final VoidCallback? onSend;
  final bool Function()? onAcceptPrediction;
  final Widget child;

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event.synthesized ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final value = controller.value;
    if (keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed ||
        (value.isComposingRangeValid && !value.composing.isCollapsed)) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab &&
        event.physicalKey == PhysicalKeyboardKey.tab &&
        event is KeyDownEvent &&
        !keyboard.isControlPressed &&
        onAcceptPrediction?.call() == true) {
      return KeyEventResult.handled;
    }
    // Android IMEs can also emit a logical Enter with no hardware scan code.
    // In that case Flutter uses a platform fallback, not a physical Enter key.
    if ((event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.numpadEnter) ||
        (event.physicalKey != PhysicalKeyboardKey.enter &&
            event.physicalKey != PhysicalKeyboardKey.numpadEnter)) {
      return KeyEventResult.ignored;
    }
    // Holding Enter must not send twice or add an accidental newline.
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (keyboard.isControlPressed) {
      final selection = value.selection;
      final valid = selection.isValid && selection.end <= value.text.length;
      final start = valid ? selection.start : value.text.length;
      final end = valid ? selection.end : value.text.length;
      controller.value = TextEditingValue(
        text: value.text.replaceRange(start, end, '\n'),
        selection: TextSelection.collapsed(offset: start + 1),
      );
    } else {
      onSend?.call();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        onKeyEvent: _handleKey,
        child: child,
      );
}
