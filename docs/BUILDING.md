# Building

The project intentionally does not require the Raspberry Pi development host to
carry Android, Gradle, DevEco, or OpenHarmony toolchains. GitHub Actions is the
authoritative build environment.

## CI toolchains

| Target | Pinned toolchain | Output |
| --- | --- | --- |
| Android | Flutter 3.35.7, JDK 17 | arm64-v8a, armeabi-v7a, x86_64 APKs and AAB |
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

The OpenHarmony HAP is intentionally unsigned. Signing identities and provision
profiles belong to the distributor and must not be committed to a public
repository. Sign the HAP with DevEco Studio or the HarmonyOS signing tools before
installing it on devices that reject unsigned packages.

Android credentials use `flutter_secure_storage` backed by Android Keystore.
Application backup is disabled so encrypted preferences cannot be restored onto
a device without the matching keystore key. OpenHarmony uses its dedicated
secure-storage implementation.

## Remote host requirements

- POSIX shell and OpenSSH server with Unix-socket forwarding enabled.
- `AcceptEnv` permission in `sshd_config` for every profile environment name.
- A current Codex CLI whose `codex app-server` supports Unix listeners.
- A writable `$HOME` and either `$XDG_CACHE_HOME` or `$HOME/.cache`.
- Network access required by the selected Codex provider.

For example, a profile containing `SetEnv LC_CODEX_BACKEND=sub2api` requires:

```text
AcceptEnv LC_CODEX_BACKEND
```

The app sends accepted values with SSH environment requests rather than shell
interpolation. It creates only
`${XDG_CACHE_HOME:-$HOME/.cache}/android-ssh-codex/app-server.sock`. When the
profile environment fingerprint changes, it validates and restarts that
app-owned process. It does not inspect, replace, or stop the sockets and
processes used by Codex Desktop, the CLI, or IDE extensions.
