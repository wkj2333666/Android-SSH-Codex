import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

typedef SshCommandRunner = Future<List<int>> Function(
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
    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = BigInt.parse('ffffffffffffffff', radix: 16);
    for (final byte in utf8.encode(jsonEncode(canonical))) {
      hash = ((hash ^ BigInt.from(byte)) * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static String bootstrapCommand(Map<String, String> environment) =>
      "environment_fingerprint='${environmentFingerprint(environment)}'\n"
      '$bootstrapScript';

  static Future<List<int>> bootstrap(
    SshCommandRunner run, {
    required Map<String, String> environment,
  }) async {
    try {
      return await run(
        bootstrapCommand(environment),
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
