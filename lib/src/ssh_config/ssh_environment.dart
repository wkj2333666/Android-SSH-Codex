final _sshEnvironmentName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

bool isValidSshEnvironmentName(String name) =>
    _sshEnvironmentName.hasMatch(name);

MapEntry<String, String> parseSshEnvironmentAssignment(String assignment) {
  final separator = assignment.indexOf('=');
  if (separator < 0) {
    throw const FormatException(
      'Environment assignment must contain an equals sign.',
    );
  }

  final name = assignment.substring(0, separator);
  if (!isValidSshEnvironmentName(name)) {
    throw const FormatException('Invalid environment variable name.');
  }

  final value = assignment.substring(separator + 1);
  if (value.contains('\u0000') ||
      value.contains('\r') ||
      value.contains('\n')) {
    throw const FormatException(
      'Environment variable value contains a forbidden control character.',
    );
  }

  return MapEntry(name, value);
}

Map<String, String> parseSshEnvironmentLines(String source) {
  final environment = <String, String>{};
  final lines = source.split(RegExp(r'\r?\n'));

  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    if (line.trim().isEmpty) continue;

    late final MapEntry<String, String> assignment;
    try {
      assignment = parseSshEnvironmentAssignment(line);
    } on FormatException catch (error) {
      throw FormatException(
        'Invalid environment assignment on line ${index + 1}: '
        '${error.message}',
      );
    }

    if (environment.containsKey(assignment.key)) {
      throw FormatException(
        'Duplicate environment variable ${assignment.key} '
        'on line ${index + 1}.',
      );
    }
    environment[assignment.key] = assignment.value;
  }

  return Map.unmodifiable(environment);
}

String formatSshEnvironmentLines(Map<String, String> environment) {
  final names = environment.keys.toList()..sort();
  return names.map((name) => '$name=${environment[name]}').join('\n');
}

String? validateSshEnvironmentLines(String? source) {
  try {
    parseSshEnvironmentLines(source ?? '');
    return null;
  } on FormatException catch (error) {
    return error.message.toString();
  }
}
