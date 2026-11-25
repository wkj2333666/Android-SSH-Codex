// Used by test_windows_codex.py to exercise the actual mobile command builders.
import 'dart:convert';
import 'dart:io';
import 'package:android_ssh_codex/src/transport/windows_commands.dart';

void main(List<String> args) {
  stdout.writeln(jsonEncode({
    'start': windowsCodexCommand(['app-server', 'daemon', 'start']),
    'stop': windowsCodexCommand(['app-server', 'daemon', 'stop']),
    'proxy':
        windowsCodexCommand(['app-server', 'proxy', '--sock', args.single]),
  }));
}
