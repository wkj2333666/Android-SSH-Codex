import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';

import '../diagnostics_redaction.dart';

final class SshCommandResult {
  const SshCommandResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.exitSignal,
  });

  final List<int> stdout;
  final List<int> stderr;
  final int? exitCode;
  final String? exitSignal;
}

final class CodexBootstrapException implements Exception {
  const CodexBootstrapException(
    this.message, {
    this.reason = 'bootstrap_failed',
    this.exitCode,
    this.exitSignal,
  });

  final String message;
  final String reason;
  final int? exitCode;
  final String? exitSignal;

  @override
  String toString() => message;
}

typedef SshCommandRunner = Future<SshCommandResult> Function(
  String command, {
  Map<String, String>? environment,
});

final class CodexDaemon {
  const CodexDaemon._();

  static String environmentFingerprint(Map<String, String> environment) {
    final names = environment.keys.toList()..sort();
    final canonical = <String, String>{
      for (final name in names) name: environment[name]!,
    };
    return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
  }

  static String _bootstrapPayload(Map<String, String> environment) =>
      "environment_fingerprint='${environmentFingerprint(environment)}'\n"
      '$bootstrapScript';

  static String _shellCommand(String script) {
    final payload = base64Encode(utf8.encode(script));
    return "printf '%s' '$payload' | base64 -d | /bin/sh";
  }

  static String _shellCommandPreservingStdin(String script) {
    final payload = base64Encode(utf8.encode(script));
    return "/bin/sh -c 'exec /bin/sh -c "
        "\"\$(printf %s $payload | base64 -d)\"'";
  }

  static String bootstrapCommand(Map<String, String> environment) =>
      _shellCommand(_bootstrapPayload(environment));

  static String get sharedStartCommand =>
      _shellCommand('exec codex app-server daemon start');

  static String proxyCommand(String socketPath) => _shellCommandPreservingStdin(
        'exec codex app-server proxy --sock ${_shellQuote(socketPath)}',
      );

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\"'\"'")}'";

  static Future<String> bootstrap(
    SshCommandRunner run, {
    required Map<String, String> environment,
  }) async {
    final result = await _runWithEnvironment(
      run,
      bootstrapCommand(environment),
      environment,
    );

    final failures = <String>[
      if (result.exitCode != null && result.exitCode != 0)
        'exit code ${result.exitCode}',
      if (result.exitSignal != null) 'signal ${result.exitSignal}',
    ];
    if (failures.isNotEmpty) {
      throw CodexBootstrapException(
        'Remote Codex bootstrap failed with ${failures.join(' and ')}: '
        '${_diagnostic(result, environment)}',
        reason: 'bootstrap_command_failed',
        exitCode: result.exitCode,
        exitSignal: result.exitSignal,
      );
    }

    final output = utf8.decode(result.stdout, allowMalformed: true);
    final socketPath = output
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.endsWith('app-server.sock'))
        .lastOrNull;
    if (socketPath == null) {
      throw CodexBootstrapException(
        'Remote Codex bootstrap did not report its socket: '
        '${_diagnostic(result, environment)}',
        reason: 'bootstrap_socket_missing',
      );
    }
    return socketPath;
  }

  static Future<String> startShared(
    SshCommandRunner run, {
    required Map<String, String> environment,
  }) async {
    final result = await _runWithEnvironment(
      run,
      sharedStartCommand,
      environment,
    );
    if (_commandFailed(result)) {
      if (_daemonSubcommandIsUnsupported(result)) {
        return _probeExistingSharedSocket(run, environment);
      }
      throw CodexBootstrapException(
        'Shared app-server start failed with ${_failureSummary(result)}: '
        '${_diagnostic(result, environment)}',
        reason: 'shared_start_failed',
        exitCode: result.exitCode,
        exitSignal: result.exitSignal,
      );
    }

    final output = utf8.decode(result.stdout, allowMalformed: true).trim();
    Object? decoded;
    try {
      decoded = jsonDecode(output);
    } on FormatException {
      throw CodexBootstrapException(
        'Shared app-server daemon returned invalid JSON: '
        '${_diagnostic(result, environment)}',
        reason: 'shared_start_invalid_json',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const CodexBootstrapException(
        'Shared app-server daemon returned invalid JSON: expected an object.',
        reason: 'shared_start_invalid_shape',
      );
    }
    final socketPath = decoded['socketPath'];
    if (socketPath is! String || !_isAbsoluteUnixSocketPath(socketPath)) {
      throw const CodexBootstrapException(
        'Shared app-server daemon returned an invalid socketPath.',
        reason: 'shared_start_invalid_socket',
      );
    }
    return socketPath;
  }

  static Future<SshCommandResult> _runWithEnvironment(
    SshCommandRunner run,
    String command,
    Map<String, String> environment,
  ) async {
    try {
      return await run(
        command,
        environment: environment.isEmpty ? null : environment,
      );
    } on SSHChannelRequestError catch (error) {
      final match = RegExp(
        r'^Failed to set environment variable: ([A-Za-z_][A-Za-z0-9_]*)$',
      ).firstMatch(error.message);
      if (match == null) rethrow;
      final name = match.group(1)!;
      throw StateError(
        'The SSH server rejected SetEnv $name. Allow it with AcceptEnv $name '
        'in sshd_config, or remove it from this profile.',
      );
    }
  }

  static Future<String> _probeExistingSharedSocket(
    SshCommandRunner run,
    Map<String, String> environment,
  ) async {
    final result = await _runWithEnvironment(
      run,
      _shellCommand(_sharedSocketProbeScript),
      environment,
    );
    if (_commandFailed(result)) {
      throw CodexBootstrapException(
        'Shared app-server is unavailable with this Codex version. Update '
        'Codex, or select Custom or Isolated. ${_diagnostic(result, environment)}',
        reason: 'shared_socket_unavailable',
        exitCode: result.exitCode,
        exitSignal: result.exitSignal,
      );
    }
    final socketPath = utf8.decode(result.stdout, allowMalformed: true).trim();
    if (!_isAbsoluteUnixSocketPath(socketPath)) {
      throw const CodexBootstrapException(
        'Shared app-server socket probe returned an invalid path. Update '
        'Codex, or select Custom or Isolated.',
        reason: 'shared_probe_invalid_socket',
      );
    }
    return socketPath;
  }

  static bool _commandFailed(SshCommandResult result) =>
      (result.exitCode != null && result.exitCode != 0) ||
      result.exitSignal != null;

  static String _failureSummary(SshCommandResult result) {
    final failures = <String>[
      if (result.exitCode != null && result.exitCode != 0)
        'exit code ${result.exitCode}',
      if (result.exitSignal != null) 'signal ${result.exitSignal}',
    ];
    return failures.join(' and ');
  }

  static bool _daemonSubcommandIsUnsupported(SshCommandResult result) {
    final output = utf8.decode(
      [...result.stderr, ...result.stdout],
      allowMalformed: true,
    );
    return RegExp(
      r'''(?:unrecognized|unknown) subcommand\s+['"]daemon['"]''',
      caseSensitive: false,
    ).hasMatch(output);
  }

  static bool _isAbsoluteUnixSocketPath(String value) =>
      value.isNotEmpty &&
      value.startsWith('/') &&
      !RegExp(r'[\x00-\x1F\x7F]').hasMatch(value);

  static String _diagnostic(
      SshCommandResult result, Map<String, String> environment) {
    final text = [
      if (result.stderr.isNotEmpty)
        'stderr: ${utf8.decode(result.stderr, allowMalformed: true)}',
      if (result.stdout.isNotEmpty)
        'stdout: ${utf8.decode(result.stdout, allowMalformed: true)}',
    ].join('\n');
    return _boundedDiagnostic(
        utf8.encode(redactBootstrapDiagnostic(text, environment.values)));
  }

  static const _maxDiagnosticCharacters = 1200;

  static const _sharedSocketProbeScript = r'''
set -eu
socket="${CODEX_HOME:-$HOME/.codex}/app-server-control/app-server-control.sock"
if [ -S "$socket" ]; then
  printf '%s\n' "$socket"
  exit 0
fi
printf '%s\n' "No existing shared app-server socket at $socket" >&2
exit 1
''';

  static String _boundedDiagnostic(List<int> bytes) {
    var text = utf8.decode(bytes, allowMalformed: true).trim();
    text = text.replaceAll(
      RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'),
      '?',
    );
    if (text.isEmpty) return 'No diagnostic output was returned.';
    if (text.length <= _maxDiagnosticCharacters) return text;
    return '${text.substring(0, _maxDiagnosticCharacters - 3)}...';
  }

  static const bootstrapScript = r'''
set -eu
umask 077
: "${environment_fingerprint:?Missing environment fingerprint}"
base="${XDG_CACHE_HOME:-$HOME/.cache}/android-ssh-codex"
socket="$base/app-server.sock"
pidfile="$base/app-server.pid"
fingerprint_file="$base/environment-fingerprint"
lock="$base/start.lock"
log="$base/app-server.log"
mkdir -p "$base"
chmod 700 "$base"

is_our_server_running() {
  [ -r "$pidfile" ] || return 1
  pid=$(cat "$pidfile" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ -r "/proc/$pid/cmdline" ]; then
    command=$(tr '\000' ' ' < "/proc/$pid/cmdline")
  else
    command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  fi
  case "$command" in
    *"codex app-server"*"unix://$socket"*) return 0 ;;
    *) return 1 ;;
  esac
}

environment_fingerprint_matches() {
  [ -r "$fingerprint_file" ] || return 1
  current_fingerprint=$(cat "$fingerprint_file" 2>/dev/null || true)
  [ "$current_fingerprint" = "$environment_fingerprint" ]
}

count=0
while ! mkdir "$lock" 2>/dev/null; do
  count=$((count + 1))
  if [ "$count" -ge 100 ]; then
    if find "$lock" -type d -mmin +1 -print -quit | grep -q . &&
       rmdir "$lock" 2>/dev/null; then
      count=0
      continue
    fi
    printf '%s\n' 'Timed out waiting for Android SSH Codex app-server lock' >&2
    exit 1
  fi
  sleep 0.1
done
trap 'rmdir "$lock" 2>/dev/null || true' EXIT HUP INT TERM

stop_our_server() {
  printf '%s\n' \
    'The existing Codex app-server uses a different environment; restarting it.' \
    >&2
  kill "$pid" 2>/dev/null || true
  count=0
  while is_our_server_running; do
    count=$((count + 1))
    if [ "$count" -ge 100 ]; then
      printf '%s\n' 'Timed out stopping the existing Codex app-server' >&2
      exit 1
    fi
    sleep 0.1
  done
}

if is_our_server_running; then
  if [ -S "$socket" ] && environment_fingerprint_matches; then
    printf '%s\n' "$socket"
    exit 0
  fi
  if environment_fingerprint_matches; then
    printf '%s\n' "App-server process is alive but $socket is unavailable; inspect $log" >&2
    exit 1
  fi
  stop_our_server
fi
rm -f "$socket" "$pidfile" "$fingerprint_file"
nohup codex app-server --listen "unix://$socket" </dev/null >>"$log" 2>&1 &
printf '%s\n' "$!" >"$pidfile"
count=0
while [ "$count" -lt 100 ]; do
  if [ -S "$socket" ]; then
    fingerprint_tmp="$fingerprint_file.$$"
    printf '%s\n' "$environment_fingerprint" >"$fingerprint_tmp"
    chmod 600 "$fingerprint_tmp"
    mv "$fingerprint_tmp" "$fingerprint_file"
    printf '%s\n' "$socket"
    exit 0
  fi
  count=$((count + 1))
  sleep 0.1
done
printf '%s\n' "Codex app-server did not create $socket; inspect $log" >&2
exit 1
''';
}

extension<T> on Iterable<T> {
  T? get lastOrNull {
    T? result;
    var found = false;
    for (final item in this) {
      result = item;
      found = true;
    }
    return found ? result : null;
  }
}
