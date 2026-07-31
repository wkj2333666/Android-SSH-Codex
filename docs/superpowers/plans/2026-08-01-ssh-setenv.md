# SSH SetEnv And Empty Passphrase Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix unencrypted private-key authentication with a blank passphrase and add end-to-end OpenSSH `SetEnv` support for remote Codex startup.

**Architecture:** Normalize optional key passphrases at the single SSH identity boundary shared by target and jump hosts. Parse `SetEnv` into a validated immutable profile map, edit it through a dedicated text codec, and pass it to a testable daemon bootstrap runner that delegates to dartssh2's acknowledged SSH environment requests.

**Tech Stack:** Flutter 3.35.7, Dart, dartssh2 2.22.2, flutter_test, GitHub Actions, GitHub CLI.

---

### Task 1: Normalize Blank Private-Key Passphrases

**Files:**
- Modify: `test/transport/ssh_connector_test.dart`
- Modify: `lib/src/transport/ssh_connector.dart`

- [x] **Step 1: Add a failing boundary regression test**

Add tests for a new pure helper used by both target and ProxyJump clients:

```dart
test('normalizes a blank private-key passphrase to null', () {
  expect(normalizePrivateKeyPassphrase(''), isNull);
  expect(normalizePrivateKeyPassphrase('   '), isNull);
});

test('preserves a non-empty private-key passphrase exactly', () {
  expect(normalizePrivateKeyPassphrase('  secret  '), '  secret  ');
});
```

- [x] **Step 2: Push the test-only commit and verify RED remotely**

Commit the test, push `codex/ssh-setenv`, open a draft PR, and watch the `Analyze and test` job. Expected failure: `normalizePrivateKeyPassphrase` is undefined. Do not run tests locally.

- [x] **Step 3: Implement the minimal normalization**

Add this top-level helper and use it at the existing shared `SSHKeyPair.fromPem` call:

```dart
String? normalizePrivateKeyPassphrase(String? value) =>
    value == null || value.trim().isEmpty ? null : value;

final identities = privateKey == null || privateKey.trim().isEmpty
    ? null
    : SSHKeyPair.fromPem(
        privateKey,
        normalizePrivateKeyPassphrase(passphrase),
      );
```

- [x] **Step 4: Push and verify GREEN remotely**

Expected GitHub CI: helper tests and all existing Flutter tests pass; analysis is clean. Confirm Android APK/AAB and OpenHarmony HAP jobs also pass before marking the task complete.

- [x] **Step 5: Commit**

Use commit message `fix: normalize empty SSH key passphrases`.

### Task 2: Parse And Validate SetEnv

**Files:**
- Create: `lib/src/ssh_config/ssh_environment.dart`
- Create: `test/ssh_config/ssh_environment_test.dart`
- Modify: `lib/src/ssh_config/ssh_config.dart`
- Modify: `test/ssh_config/ssh_config_parser_test.dart`

- [x] **Step 1: Add failing parser and codec tests**

Cover these public APIs and outcomes:

```dart
final backend =
    parseSshEnvironmentAssignment('LC_CODEX_BACKEND=sub2api');
expect(backend.key, 'LC_CODEX_BACKEND');
expect(backend.value, 'sub2api');
final token = parseSshEnvironmentAssignment('TOKEN=a=b');
expect(token.key, 'TOKEN');
expect(token.value, 'a=b');
expect(() => parseSshEnvironmentAssignment('NO_EQUALS'), throwsFormatException);
expect(() => parseSshEnvironmentAssignment('1BAD=value'), throwsFormatException);
```

Add config cases for multiple assignments, quoted spaces, `Host *` precedence,
duplicate-name warnings that omit values, invalid assignments, and the existing
`Unsupported SSH directive: IPQoS` warning. The desired resolved API is:

```dart
expect(host.environment, {
  'LC_CODEX_BACKEND': 'sub2api',
  'CODEX_LABEL': 'mobile client',
});
```

- [x] **Step 2: Push the test-only commit and verify RED remotely**

Expected failure: missing environment codec and `ResolvedSshHost.environment`.

- [x] **Step 3: Implement the environment codec**

Create a focused parser that splits on the first `=`, validates names with
`RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$')`, permits empty values, rejects NUL/CR/LF,
and never includes a value in `FormatException.message`.

Also expose editor helpers used in Task 4:

```dart
Map<String, String> parseSshEnvironmentLines(String source);
String formatSshEnvironmentLines(Map<String, String> environment);
String? validateSshEnvironmentLines(String? source);
```

The line parser rejects duplicate names and reports the 1-based line number.
The formatter emits entries sorted by name. The validator returns the parser's
safe line-specific message or `null` and never includes an environment value.

- [x] **Step 4: Implement directive-aware tokenization and resolution**

Replace the current equals-as-universal-separator tokenizer with a directive
splitter that treats only the first unquoted whitespace or `=` as the keyword
separator, then tokenizes arguments while preserving `=` inside `SetEnv`
assignments. Add `setenv` to `_supportedDirectives`.

Store each SetEnv token as its own directive. During resolution, validate each
assignment and add it only when the name is absent. A conflicting later value
adds `Duplicate SetEnv variable: NAME`; invalid input adds
`Invalid SetEnv assignment for NAME` or `Invalid SetEnv assignment` without
including its value. Return `Map.unmodifiable(environment)` on
`ResolvedSshHost.environment`.

- [x] **Step 5: Push and verify GREEN remotely**

Expected: all SSH config and environment tests pass, existing config semantics
remain green, analysis is clean, and both platform jobs pass.

- [x] **Step 6: Commit**

Use commit message `feat: parse SSH SetEnv directives`.

### Task 3: Persist SetEnv In Host Profiles

**Files:**
- Modify: `lib/src/profiles/host_profile.dart`
- Modify: `test/profiles/host_profile_test.dart`
- Modify: `test/ui/app_smoke_test.dart`

- [ ] **Step 1: Add failing profile tests**

Extend import and JSON tests to require the environment map, verify old JSON
without `environment` loads as `{}`, verify `copyWith(environment: {})` clears
it, and verify equality/hash behavior uses map contents rather than map identity.

```dart
expect(HostProfile.fromResolved(config.resolve('pi')).environment,
    {'LC_CODEX_BACKEND': 'sub2api'});
expect(HostProfile.fromJson(oldJson).environment, isEmpty);
expect(HostProfile.fromJson(profile.toJson()), profile);
```

- [ ] **Step 2: Push the test-only commit and verify RED remotely**

Expected failure: `HostProfile.environment` and the `copyWith` parameter do not
exist.

- [ ] **Step 3: Implement immutable profile storage**

Change `HostProfile` to a factory backed by a private constructor so every
incoming map is copied with `Map.unmodifiable`. Include `environment` in
`fromResolved`, `fromJson`, `copyWith`, and `toJson` (omit when empty).
Implement content-based map equality and a stable entry hash. Remove `const`
from the one test fixture that constructs `HostProfile` directly.

- [ ] **Step 4: Push and verify GREEN remotely**

Expected: profile, startup, and UI smoke tests pass; old profile JSON remains
compatible; platform builds pass.

- [ ] **Step 5: Commit**

Use commit message `feat: persist SSH environment profiles`.

### Task 4: Edit Environment Variables In The Profile Dialog

**Files:**
- Modify: `lib/src/ui/profile_editor.dart`
- Modify: `test/ui/profile_editor_test.dart`

- [ ] **Step 1: Add failing widget tests**

Cover an existing profile rendering sorted `NAME=value` lines, SSH config
import filling the field, a missing `=` preventing Save with a line-specific
error, duplicate names preventing Save, and a valid Save returning a
`ProfileDraft.profile.environment` map.

- [ ] **Step 2: Push the test-only commit and verify RED remotely**

Expected failure: no `Advanced SSH` tile or `Environment variables` field.

- [ ] **Step 3: Implement the editor**

Add an `_environment` controller initialized with
`formatSshEnvironmentLines(profile?.environment ?? const {})`, dispose it,
and render this control after ProxyJump:

```dart
ExpansionTile(
  tilePadding: EdgeInsets.zero,
  title: const Text('Advanced SSH'),
  children: [
    TextFormField(
      controller: _environment,
      minLines: 3,
      maxLines: 8,
      style: const TextStyle(fontFamily: 'monospace'),
      decoration: const InputDecoration(
        labelText: 'Environment variables',
        alignLabelWithHint: true,
      ),
      validator: validateSshEnvironmentLines,
    ),
  ],
)
```

On import, replace its text with the resolved environment. On save, parse once
after form validation and pass the map to `HostProfile(environment: ...)`.

- [ ] **Step 4: Push and verify GREEN remotely**

Expected: all widget tests pass without overflow at the existing test viewport;
analysis and both platform builds pass.

- [ ] **Step 5: Commit**

Use commit message `feat: edit SSH environment variables`.

### Task 5: Apply SetEnv To Codex Bootstrap

**Files:**
- Modify: `lib/src/transport/codex_daemon.dart`
- Modify: `lib/src/app_controller.dart`
- Modify: `test/transport/codex_daemon_test.dart`
- Modify: `test/app_controller_startup_test.dart`

- [ ] **Step 1: Add failing command-boundary tests**

Define the desired injectable runner contract in tests:

```dart
typedef SshCommandRunner = Future<List<int>> Function(
  String command, {
  Map<String, String>? environment,
});
```

Test that `CodexDaemon.bootstrap` invokes the runner once with
`CodexDaemon.bootstrapScript` and the exact immutable profile map. Add a
rejection test whose runner throws
`SSHChannelRequestError('Failed to set environment variable: SECRET_NAME')`;
the surfaced error must contain `SECRET_NAME` and `AcceptEnv`, and must not
contain the configured value.

- [ ] **Step 2: Push the test-only commit and verify RED remotely**

Expected failure: `CodexDaemon.bootstrap` and the runner boundary are absent.

- [ ] **Step 3: Implement the bootstrap boundary**

Add `CodexDaemon.bootstrap` accepting the runner and environment. It delegates
without shell interpolation and catches only the dartssh2 environment rejection
shape to throw an actionable `StateError`:

```dart
throw StateError(
  'The SSH server rejected SetEnv $name. Allow it with AcceptEnv $name '
  'in sshd_config, or remove it from this profile.',
);
```

Never include the environment value. Update `AppController` to call the helper
using `ssh.client.run` and `profile.environment`, then decode its output exactly
as before.

- [ ] **Step 4: Push and verify GREEN remotely**

Expected: the command-boundary and controller tests pass, all existing tests
remain green, and Android/OpenHarmony builds pass.

- [ ] **Step 5: Commit**

Use commit message `feat: apply SSH environment to Codex bootstrap`.

### Task 6: Document, Review, And Release

**Files:**
- Modify: `README.md`
- Modify: `docs/BUILDING.md`
- Modify: `pubspec.yaml`

- [ ] **Step 1: Update user and server documentation**

Document imported `SetEnv`, the Advanced SSH editor, the remote
`AcceptEnv LC_CODEX_BACKEND` requirement, and an example using
`LC_CODEX_BACKEND=sub2api`. State that arbitrary directives including `IPQoS`
are not supported. Document that blank passphrases work with unencrypted keys.

- [ ] **Step 2: Set release version**

Set `pubspec.yaml` to `version: 0.1.2+4`. Build number 4 is greater than the
diagnostic `v0.1.2-rc.1` package while the release does not include that branch's
Impeller change.

- [ ] **Step 3: Push and obtain final CI evidence**

Verify the exact HEAD has passing `Analyze and test`, Android APK/AAB, and
OpenHarmony HAP jobs. Do not use local Flutter commands.

- [ ] **Step 4: Run two-stage and final code review**

For each implementation task, require spec compliance followed by code-quality
approval. Then request a final review of `main..HEAD`, resolve every Critical or
Important finding, and rerun remote CI after any code change.

- [ ] **Step 5: Merge and publish**

Mark the draft PR ready, squash-merge after checks, tag the merged main commit
as `v0.1.2`, and watch the tag workflow publish APK/AAB/HAP/checksum assets.
Verify the release is non-draft, non-prerelease, and latest; download the arm64
APK and compare its SHA-256 with `SHA256SUMS.txt`.

- [ ] **Step 6: Commit**

Use commit message `docs: document SSH SetEnv configuration`.
