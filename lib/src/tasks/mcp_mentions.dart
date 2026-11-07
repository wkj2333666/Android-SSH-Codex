final _code = RegExp(r'```[\s\S]*?(?:```|$)|`[^`\n]*`');
final _token = RegExp(r'(^|[\s(\[，。；：！？])\$([A-Za-z_][A-Za-z0-9_-]*)(?=$|[\s.,;:!?)\]，。；：！？])');

/// Only named dollar tokens are candidates. Resolve against the selected
/// thread's MCP catalog before making them structured inputs.
List<String> mcpMentionNames(String text, {String? skillName}) {
  if (!text.contains(r'$')) return const [];
  final names = <String>{};
  for (final match in _token.allMatches(text.replaceAll(_code, ' '))) {
    final name = match[2]!;
    if (name != skillName) names.add(name);
    if (names.length == 16) break;
  }
  return names.toList(growable: false);
}

final class McpMention {
  const McpMention(this.name, {this.pluginId});
  final String name;
  final String? pluginId;

  Map<String, String> toInput() => {
    'type': 'mention', 'name': name,
    'path': pluginId == null ? 'mcp://${Uri.encodeComponent(name)}' : 'plugin://$pluginId',
  };
}
