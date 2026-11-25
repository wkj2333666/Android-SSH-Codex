# Building

The project intentionally does not require the Raspberry Pi development host to
carry Android, Gradle, DevEco, or OpenHarmony toolchains. GitHub Actions is the
authoritative build environment.

## CI toolchains

| Target | Pinned toolchain | Output |
| --- | --- | --- |
| Android | Flutter 3.35.7, JDK 17 | stably signed arm64-v8a, armeabi-v7a, x86_64 APKs and AAB |
| OpenHarmony | Flutter-OH commit `244a0e8abb3085e8675589b13e219af8c41cb7aa`, OpenHarmony SDK 6.1.1.280, JDK 17 | unsigned arm64 HAP |

The OpenHarmony setup Action is pinned to commit
`4dbb63025116eb6165ceac58a4bf47cbdc5ac721`. Platform shells are generated on
the runner and normalized by `tool/prepare_android.sh` and
`tool/prepare_ohos.sh`. This keeps generated toolchain churn out of source
control while preserving deterministic identifiers and permissions.

## Workflows

- `CI` resolves dependencies, checks formatting, runs `flutter analyze`, and
  runs all unit and widget tests.
- `Platform builds` builds Android and OpenHarmony in parallel, uploads each
  artifact with SHA-256 sums, and caches all large dependency layers.
- A tag matching `v*` publishes the combined artifacts as a GitHub Release.

## Android release signing

Android release signing uses one retained RSA-4096 identity stored as an
encrypted PKCS#12 keystore. The workflow restores it only from these repository
Secrets:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

The public certificate fingerprint is stored in the repository variable
`ANDROID_SIGNING_CERT_SHA256`. Every release-tag build verifies all APK and AAB
signatures against that fingerprint before uploading artifacts. A tag build
fails if any signing input is absent or the fingerprint differs. Pull requests
without access to Secrets retain Flutter's generated debug-signing fallback and
cannot publish a release.

The recovery copy is outside the repository at
`~/.config/android-ssh-codex/signing/`. The directory must remain mode `0700`
and its contents mode `0600`. Back it up offline. Deleting or replacing both the
recovery copy and GitHub Secrets permanently prevents future APKs from updating
installed stable-signed versions.

`v0.1.5` is the signing migration baseline. Builds through `v0.1.4` used
ephemeral GitHub runner identities whose private keys no longer exist. Those
users must uninstall once before installing `v0.1.5`; releases after `v0.1.5`
can update it in place.

The OpenHarmony HAP remains intentionally unsigned. Signing identities and provision
profiles belong to the distributor and must not be committed to a public
repository. Sign the HAP with DevEco Studio or the HarmonyOS signing tools before
installing it on devices that reject unsigned packages.

Android credentials use `flutter_secure_storage` backed by Android Keystore.
Application backup is disabled so encrypted preferences cannot be restored onto
a device without the matching keystore key. OpenHarmony uses its dedicated
secure-storage implementation.

## Remote host requirements

The following shell requirements are for Linux/macOS. Windows uses PowerShell
and the native Codex control-socket proxy; see [Windows hosts](WINDOWS.md).
Windows supports Shared and Custom, with explicit drive-path validation and
byte-preserving SSH proxy transport. Isolated remains POSIX-only.

- `/bin/sh`, a `base64` command, and an OpenSSH server with Unix-socket
  forwarding enabled. The account login shell may be fish, Bash, Zsh, or
  another shell that supports ordinary commands, quoting, and pipelines.
- `AcceptEnv` permission in `sshd_config` for every profile environment name.
- Codex CLI 0.146.0 or newer for the Shared daemon lifecycle command. Older
  versions can use Shared only when their standard app-server control socket is
  already running.
- A current Codex CLI whose `codex app-server proxy --sock` supports the selected
  Unix socket.
- A writable `$HOME`; Isolated mode also requires a writable
  `$XDG_CACHE_HOME` or `$HOME/.cache`.
- Network access required by the selected Codex provider.

For example, a profile containing `SetEnv LC_CODEX_BACKEND=sub2api` requires:

```text
AcceptEnv LC_CODEX_BACKEND
```

The app sends accepted values with SSH environment requests rather than shell
interpolation. Every Host independently selects one app-server mode:

- Shared runs `codex app-server daemon start`, parses its JSON `socketPath`, and
  reuses that Codex-managed daemon without restarting or stopping it.
- Custom attaches to the configured absolute control socket without running any
  lifecycle command.
- Isolated creates
  `${XDG_CACHE_HOME:-$HOME/.cache}/android-ssh-codex/app-server.sock`. When the
  profile environment fingerprint changes, it validates and restarts only that
  app-owned process.

Duplicate Hosts may point to the same SSH endpoint with different modes. The
mode is authoritative: connection failures never trigger a fallback to another
daemon or socket.
