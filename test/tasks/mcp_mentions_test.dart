import 'package:android_ssh_codex/src/tasks/mcp_mentions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('typed references are deduplicated and exclude code and selected skill', () {
    expect(mcpMentionNames(r'用 $ssh-bridge，$ssh-bridge 和 $camera。`$literal` $chosen \$escaped $20', skillName: 'chosen'), ['ssh-bridge', 'camera']);
    expect(mcpMentionNames('```${r'$example'}```'), isEmpty);
  });
  test('MCP input carries the native mention namespace and original name', () {
    expect(const McpMention('ssh-bridge').toInput(), {
      'type': 'mention', 'name': 'ssh-bridge', 'path': 'mcp://ssh-bridge',
    });
  });
}
