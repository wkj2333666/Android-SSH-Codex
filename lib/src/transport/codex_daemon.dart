import 'package:dartssh2/dartssh2.dart';

typedef SshCommandRunner = Future<List<int>> Function(
  String command, {
  Map<String, String>? environment,
});

final class CodexDaemon {
  const CodexDaemon._();

  static Future<List<int>> bootstrap(
    SshCommandRunner run, {
    required Map<String, String> environment,
  }) async {
    try {
      return await run(
        bootstrapScript,
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
base="${XDG_CACHE_HOME:-$HOME/.cache}/android-ssh-codex"
socket="$base/app-server.sock"
pidfile="$base/app-server.pid"
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

if [ -S "$socket" ] && is_our_server_running; then
  printf '%s\n' "$socket"
  exit 0
fi

count=0
while ! mkdir "$lock" 2>/dev/null; do
  if [ -S "$socket" ] && is_our_server_running; then
    printf '%s\n' "$socket"
    exit 0
  fi
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
if is_our_server_running; then
  if [ -S "$socket" ]; then
    printf '%s\n' "$socket"
    exit 0
  fi
  printf '%s\n' "App-server process is alive but $socket is unavailable; inspect $log" >&2
  exit 1
fi
rm -f "$socket" "$pidfile"
nohup codex app-server --listen "unix://$socket" </dev/null >>"$log" 2>&1 &
printf '%s\n' "$!" >"$pidfile"
count=0
while [ "$count" -lt 100 ]; do
  if [ -S "$socket" ]; then
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
