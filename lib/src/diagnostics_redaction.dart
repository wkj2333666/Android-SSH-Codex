String redactBootstrapDiagnostic(
    String value, Iterable<String> sensitiveValues) {
  var text = value;
  // Redact known profile values before truncation, longest first.
  final secrets = sensitiveValues.where((s) => s.isNotEmpty).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final secret in secrets) {
    text = text.replaceAll(secret, '[redacted]');
  }
  text = text.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
  text = text.replaceAll(
      RegExp(r'-----BEGIN[\s\S]*?-----END[^\n]*-----'), '[redacted key]');
  text =
      text.replaceAll(RegExp(r'(?:(?:sk|sess)-)[A-Za-z0-9_-]+'), '[redacted]');
  text = text.replaceAll(
      RegExp(r'Bearer\s+\S+', caseSensitive: false), 'Bearer [redacted]');
  text = text.replaceAllMapped(
      RegExp(r'(https?://)[^\s/@]+:[^\s/@]+@', caseSensitive: false),
      (match) => '${match[1]}[redacted]@');
  text = text.replaceAllMapped(
      RegExp(
          r'''(["']?(?:[\w-]*(?:token|password|secret|api[_-]?key)|authorization)["']?\s*[:=]\s*)[^\r\n]+''',
          caseSensitive: false),
      (match) => '${match[1]}[redacted]');
  text = text.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '?');
  return text.length <= 1600 ? text : '${text.substring(0, 1600)}…';
}
