# SSH SetEnv Design

## Goal

Android SSH Codex will import, edit, persist, and apply OpenSSH `SetEnv`
directives for the target host. A profile such as:

```sshconfig
Host codex-pi
  HostName 192.0.2.10
  User codex
  SetEnv LC_CODEX_BACKEND=sub2api
```

must start the remote Codex daemon with `LC_CODEX_BACKEND=sub2api` in its
environment.

This change does not add general OpenSSH option passthrough. In particular,
`IPQoS` remains unsupported and produces the existing unsupported-directive
warning during import.

## Supported Syntax And Resolution

`SetEnv` accepts one or more `NAME=VALUE` assignments on a directive. Multiple
`SetEnv` directives may appear in a matching host configuration. Values may be
quoted in imported OpenSSH config and may contain spaces or additional `=`
characters.

Environment names must match `[A-Za-z_][A-Za-z0-9_]*`. Values may be empty but
must not contain NUL, carriage-return, or newline characters. Invalid
assignments are omitted and reported as import warnings.

Resolution follows the parser's existing OpenSSH-style section order. For each
environment name, the first value obtained from matching `Host` sections wins.
Repeating the same name with a different value produces a warning identifying
the name; the value is never included in the warning. The resolved map is
immutable.

`SetEnv` applies only to command sessions on the resolved target host. A jump
host remains a transport hop and does not receive the target profile's
environment.

## Profile Model And Persistence

`ResolvedSshHost` and `HostProfile` gain an immutable `Map<String, String>` for
the resolved environment. `HostProfile.fromResolved`, `copyWith`, equality,
hashing, and JSON serialization include the map.

Old stored profiles have no environment field and load as an empty map. Empty
maps may be omitted from JSON. Profile data already uses the secure profile
store, but environment values are still treated as sensitive operational data:
they must not be written to logs or error messages.

## Profile Editor

The profile dialog gains an `Advanced SSH` expansion below authentication and
jump-host controls. It contains one multiline monospace field labeled
`Environment variables`. Each non-empty line is one literal `NAME=VALUE`
assignment. The editor splits only on the first `=`, so values may contain
additional equals signs.

Opening an existing profile renders entries in stable name order. Importing an
SSH config replaces the field with the selected alias's resolved environment.
Saving validates every non-empty line and blocks submission with a field-level
error for an invalid name, missing `=`, forbidden control character, or
duplicate name. The UI does not expose `IPQoS`.

## Remote Execution

The daemon bootstrap command is executed with the profile environment through
the `environment` argument of `dartssh2`'s `SSHClient.run`. The bootstrap shell
and the background Codex app-server process inherit the accepted variables.
Forwarding channels do not need environment requests.

The call is placed behind a small command-running boundary so tests can verify
the exact command and environment without opening a network connection. No
environment assignment is interpolated into shell source.

`dartssh2 2.22.2` waits for each server acknowledgement before executing the
command. If `sshd` rejects a variable, connection setup stops and the app shows
an actionable error naming the rejected variable and explaining that the
server must allow it with `AcceptEnv` or the profile must remove it. The value
is not shown. This is preferable to silently launching Codex with the wrong
backend.

## Error Handling

- Parser errors are non-fatal warnings and preserve every valid assignment.
- Manual editor errors prevent saving and identify the offending line.
- Server rejection prevents daemon bootstrap and leaves no partially connected
  app state.
- Existing connection cleanup closes the SSH clients and any opened tunnel on
  failure.
- Environment values never appear in logs, warnings, or connection errors.

## Testing And Delivery

Test-first remote CI coverage will include:

- parsing single and multiple `SetEnv` assignments, quoted values, matching
  sections, first-value precedence, duplicates, and invalid assignments;
- retaining an unsupported warning for `IPQoS`;
- profile import, `copyWith`, equality, backward-compatible JSON loading, and
  JSON round trips;
- profile editor import, stable rendering, validation, and saved draft output;
- daemon bootstrap passing the exact environment map to the SSH command runner
  and surfacing server rejection without exposing values;
- the complete existing Flutter test, analysis, Android build, and OpenHarmony
  build suites.

The feature starts from `main` at `v0.1.1` on `codex/ssh-setenv`, excluding the
unmerged Impeller diagnostic branch. No build or test runs on the Raspberry Pi;
all red/green TDD cycles and platform builds run in GitHub Actions.
