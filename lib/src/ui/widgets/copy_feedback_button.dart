import 'dart:async';

import 'package:flutter/material.dart';

/// Reports success on the button itself without overlaying the composer.
class CopyFeedbackButton extends StatefulWidget {
  const CopyFeedbackButton({
    required this.label,
    required this.onCopy,
    this.textButton = false,
    super.key,
  });

  final String label;
  final Future<void> Function() onCopy;
  final bool textButton;

  @override
  State<CopyFeedbackButton> createState() => _CopyFeedbackButtonState();
}

class _CopyFeedbackButtonState extends State<CopyFeedbackButton> {
  Timer? _reset;
  bool _copying = false;
  bool? _copied;

  Future<void> _copy() async {
    if (_copying) return;
    _copying = true;
    _reset?.cancel();
    var copied = false;
    try {
      await widget.onCopy();
      copied = true;
    } catch (_) {
      // The feedback stays local on failure, too.
    } finally {
      _copying = false;
    }
    if (!mounted) return;
    setState(() => _copied = copied);
    _reset = Timer(const Duration(seconds: 2), () {
      setState(() => _copied = null);
    });
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feedback = switch (_copied) {
      true => '${widget.label[0].toUpperCase()}${widget.label.substring(1)} copied',
      false => 'Could not copy ${widget.label}',
      null => 'Copy ${widget.label}',
    };
    return Semantics(
      liveRegion: _copied != null,
      child: widget.textButton
          ? TextButton(onPressed: _copy, child: Text(feedback))
          : IconButton(
              tooltip: feedback,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              onPressed: _copy,
              icon: Icon(switch (_copied) {
                true => Icons.check,
                false => Icons.error_outline,
                null => Icons.copy_all_outlined,
              }),
            ),
    );
  }
}
