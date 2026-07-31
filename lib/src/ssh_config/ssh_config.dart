import 'ssh_environment.dart';

final class SshConfig {
  SshConfig._(this._sections, this._parseWarnings);

  factory SshConfig.parse(String source) {
    final sections = <_HostSection>[
      _HostSection(const ['*'])
    ];
    var current = sections.first;
    final warnings = <String>[];

    for (final rawLine in source.split(RegExp(r'\r?\n'))) {
      final tokens = _tokenize(rawLine);
      if (tokens.isEmpty) continue;
      final first = tokens.first;
      final separator = first.indexOf('=');
      final originalKey = separator < 0 ? first : first.substring(0, separator);
      final key = originalKey.toLowerCase();
      final values = <String>[
        if (separator >= 0 && separator + 1 < first.length)
          first.substring(separator + 1),
        ...tokens.skip(1),
      ];
      if (values.isEmpty) continue;
      if (key == 'host') {
        current = _HostSection(values);
        sections.add(current);
      } else if (key == 'match') {
        current = _HostSection(const []);
        sections.add(current);
        if (!warnings.contains('Unsupported SSH directive: Match')) {
          warnings.add('Unsupported SSH directive: Match');
        }
      } else {
        if (key == 'setenv') {
          current.directives.addAll(
            values.map((value) => _Directive(key, value)),
          );
        } else {
          current.directives.add(_Directive(key, values.join(' ')));
        }
        if (!_supportedDirectives.contains(key)) {
          final warning = 'Unsupported SSH directive: $originalKey';
          if (!warnings.contains(warning)) warnings.add(warning);
        }
      }
    }

    return SshConfig._(sections, warnings);
  }

  final List<_HostSection> _sections;
  final List<String> _parseWarnings;

  ResolvedSshHost resolve(String alias) => _resolve(alias, resolveJump: true);

  ResolvedSshHost _resolve(String alias, {required bool resolveJump}) {
    String? hostName;
    String? user;
    int? port;
    String? proxyJumpValue;
    final identityFiles = <String>[];
    final environment = <String, String>{};
    final warnings = _parseWarnings.toList();

    for (final section in _sections) {
      if (!section.matches(alias)) continue;
      for (final directive in section.directives) {
        switch (directive.key) {
          case 'hostname':
            hostName ??= directive.value;
            break;
          case 'user':
            user ??= directive.value;
            break;
          case 'port':
            port ??= int.tryParse(directive.value);
            if (port == null) {
              warnings.add('Invalid Port value: ${directive.value}');
            }
            break;
          case 'identityfile':
            if (!identityFiles.contains(directive.value)) {
              identityFiles.add(directive.value);
            }
            break;
          case 'proxyjump':
            proxyJumpValue ??= directive.value;
            break;
          case 'setenv':
            late final MapEntry<String, String> assignment;
            try {
              assignment = parseSshEnvironmentAssignment(directive.value);
            } on FormatException {
              const warning = 'Invalid SetEnv assignment.';
              if (!warnings.contains(warning)) warnings.add(warning);
              break;
            }
            final name = assignment.key;
            if (!environment.containsKey(name)) {
              environment[name] = assignment.value;
            } else if (environment[name] != assignment.value) {
              final warning = 'Duplicate SetEnv variable: $name';
              if (!warnings.contains(warning)) warnings.add(warning);
            }
            break;
        }
      }
    }

    ResolvedSshHost? jump;
    if (resolveJump && proxyJumpValue != null && proxyJumpValue != 'none') {
      if (proxyJumpValue.contains(',')) {
        warnings.add('Only one ProxyJump hop is supported in this release.');
      } else {
        final jumpTarget = _parseJumpTarget(proxyJumpValue);
        final resolved = _resolve(jumpTarget.alias, resolveJump: false);
        jump = ResolvedSshHost(
          alias: jumpTarget.alias,
          hostName: resolved.hostName,
          user: jumpTarget.user ?? resolved.user,
          port: jumpTarget.port ?? resolved.port,
          identityFiles: resolved.identityFiles,
          environment: resolved.environment,
          warnings: resolved.warnings,
        );
      }
    }

    return ResolvedSshHost(
      alias: alias,
      hostName: hostName ?? alias,
      user: user,
      port: port ?? 22,
      identityFiles: List.unmodifiable(identityFiles),
      environment: Map.unmodifiable(environment),
      proxyJump: jump,
      warnings: List.unmodifiable(warnings),
    );
  }
}

const _supportedDirectives = {
  'hostname',
  'user',
  'port',
  'identityfile',
  'proxyjump',
  'setenv',
};

final class ResolvedSshHost {
  const ResolvedSshHost({
    required this.alias,
    required this.hostName,
    required this.user,
    required this.port,
    this.identityFiles = const [],
    this.environment = const {},
    this.proxyJump,
    this.warnings = const [],
  });

  final String alias;
  final String hostName;
  final String? user;
  final int port;
  final List<String> identityFiles;
  final Map<String, String> environment;
  final ResolvedSshHost? proxyJump;
  final List<String> warnings;
}

final class _HostSection {
  _HostSection(this.patterns);

  final List<String> patterns;
  final List<_Directive> directives = [];

  bool matches(String host) {
    var positive = false;
    for (final pattern in patterns) {
      final negated = pattern.startsWith('!');
      final value = negated ? pattern.substring(1) : pattern;
      if (!_globMatches(value, host)) continue;
      if (negated) return false;
      positive = true;
    }
    return positive;
  }
}

final class _Directive {
  const _Directive(this.key, this.value);

  final String key;
  final String value;
}

final class _JumpTarget {
  const _JumpTarget({required this.alias, this.user, this.port});

  final String alias;
  final String? user;
  final int? port;
}

_JumpTarget _parseJumpTarget(String value) {
  var remainder = value.trim();
  String? user;
  if (remainder.contains('@')) {
    final split = remainder.indexOf('@');
    user = remainder.substring(0, split);
    remainder = remainder.substring(split + 1);
  }
  int? port;
  var alias = remainder;
  if (remainder.contains(':')) {
    final split = remainder.lastIndexOf(':');
    port = int.tryParse(remainder.substring(split + 1));
    alias = remainder.substring(0, split);
  }
  return _JumpTarget(alias: alias, user: user, port: port);
}

bool _globMatches(String pattern, String input) {
  final buffer = StringBuffer('^');
  for (final rune in pattern.runes) {
    final char = String.fromCharCode(rune);
    switch (char) {
      case '*':
        buffer.write('.*');
        break;
      case '?':
        buffer.write('.');
        break;
      default:
        buffer.write(RegExp.escape(char));
        break;
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString(), caseSensitive: false).hasMatch(input);
}

List<String> _tokenize(String line) {
  final tokens = <String>[];
  final current = StringBuffer();
  String? quote;

  void flush() {
    if (current.isEmpty) return;
    tokens.add(current.toString());
    current.clear();
  }

  for (var index = 0; index < line.length; index++) {
    final char = line[index];
    if (quote != null) {
      if (char == quote) {
        quote = null;
      } else if (char == r'\' && index + 1 < line.length) {
        current.write(line[++index]);
      } else {
        current.write(char);
      }
      continue;
    }
    if (char == '#') break;
    if (char == '"' || char == "'") {
      quote = char;
    } else if (RegExp(r'\s').hasMatch(char)) {
      flush();
    } else {
      current.write(char);
    }
  }
  flush();
  return tokens;
}
