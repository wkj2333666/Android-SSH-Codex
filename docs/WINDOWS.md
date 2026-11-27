# Windows SSH hosts

Windows hosts run Codex natively; WSL, Bash, and a public app-server TCP port
are not required. Select **Windows** under **Host operating system** in the
mobile host editor. Existing hosts keep the Linux/macOS behavior.

## Prepare the computer

1. Install Microsoft's OpenSSH Server optional Windows feature and start `sshd`.
   Follow [Microsoft's OpenSSH installation guide](https://learn.microsoft.com/windows-server/administration/openssh/openssh_install_firstuse).
   Allow the SSH port through the firewall on the network you intend to use.
2. Install a current Windows Codex CLI for the account used to log in over SSH.
   Native `codex.exe` and the standard npm `@openai/codex` installation are
   supported. Run `codex --version`, then `codex` and complete sign-in on the
   computer. Windows host integration was tested with Codex CLI 0.167.2.
3. Confirm that a separate SSH client can log in as that same account and run
   `powershell.exe -NoProfile -Command "codex --version"`.
   Windows PowerShell 5.1 must be available. Both the normal cmd.exe SSH login
   shell and a PowerShell SSH login shell can launch the encoded commands.
4. In the mobile app, enter the computer's reachable address, SSH user, port,
   and password or private key. Select **Windows**. Use **Shared** only when
   the SSH session is non-elevated; administrator SSH logins can run with an
   elevated token even if the desktop terminal is not elevated. For those
   logins, use the **Custom** setup below. Connect and verify the SSH host
   fingerprint.
5. Add an existing project with an absolute Windows directory, for example
   `D:/Projects/my-app` or `D:\Projects\my-app`.

Keep Windows awake and the SSH server reachable. For access from another
network, use your existing VPN or SSH routing; this app does not provide a relay.

## Modes and identity

**Shared** runs `codex app-server daemon start` and uses the returned control
socket. **Custom** connects to an existing Windows control socket using its
absolute drive path, without starting or stopping its process. **Isolated**
is currently available only for Linux/macOS; selecting it for a Windows host
produces an explicit error and never silently selects another mode.

### Administrator SSH logins

Codex rejects `daemon start` from an elevated Windows process. A successful SSH
login does not establish that Shared startup is supported: an administrator
account can receive an elevated SSH session. Even an already-running daemon does
not make the elevated `daemon start` command succeed.

1. On the Windows desktop, open a normal PowerShell terminal as the same account
   used for SSH. Do not select **Run as administrator**.
2. Run `codex app-server daemon start`. Its JSON output includes `socketPath`.
3. In the mobile host editor, select **Windows → Custom**, then copy that exact
   value into **App-server Windows socket**. For a default installation it
   typically resembles `C:/Users/your-name/.codex/app-server-control/app-server-control.sock`.
   Use the returned path, especially if `CODEX_HOME` is customized.
4. Save and connect. Custom uses the existing proxy command and does not run
   `daemon start` through SSH. Start the daemon again after a Windows reboot
   or if it has stopped; Custom does not manage its lifecycle.

The app does not automatically change modes, lower process tokens, change
account privileges, or relax socket access controls. Keep the daemon itself
non-elevated. A standard Windows account with a non-elevated SSH session can
use Shared directly, but it has its own Codex identity and history unless
explicitly configured otherwise.

Codex's Windows control socket is accessed through `codex app-server proxy`.
The phone still uses a loopback WebSocket carried inside the SSH exec channel.
No additional listening TCP port is created on Windows. PowerShell profile
scripts are not loaded, and a byte-stream relay prevents PowerShell 5.1 from
converting WebSocket frames to text.

Desktop and phone share live state only when they use the same Windows account,
effective `CODEX_HOME`, and compatible app-server. Merely signing in to the same
ChatGPT account does not share local histories. Codex's managed daemon must run
without elevation. Its implicit daemon discovery checks peer identity and
elevation; Custom explicitly selects a socket using `app-server proxy --sock`
and remains subject to that socket's access controls.

## Files and environment

- Project directories, attachment paths, file links, image/video/document
  previews, and visualization links accept absolute local drive paths. UNC
  shares and Windows device paths are not supported.
- Uploads and anonymous workspaces use private directories beneath
  `%LOCALAPPDATA%\android-ssh-codex\attachments` and `workspaces`. Existing
  directories with unexpected ownership, access permissions, or reparse points
  are rejected. Upload retries keep their completed bytes.
- Uploads and downloads require the Windows OpenSSH SFTP subsystem. Drive paths
  are translated to SFTP's `/C:/...` form only at the transfer boundary.
- Port discovery uses `Get-NetTCPConnection` without requesting process names
  or arguments. Manual TCP forwarding remains available if discovery is denied.
- Codex is located using the SSH user's PATH and common per-user installation
  locations. The standard npm launcher is resolved to its native executable so
  binary SSH traffic does not pass through a shell or Node launcher.
- Advanced SSH environment variables still depend on server support for SSH
  environment requests. If the server rejects one, remove it from the profile
  and configure the SSH user's environment on the computer. Do not put provider
  credentials in the mobile app.

If Shared startup fails, check the Codex version and whether the same command
works in an SSH login under the same user. For the non-elevated-terminal error,
follow the administrator SSH setup above. If the proxy fails, confirm that the
configured socket belongs to the same user and a running daemon. Connection diagnostics identify
the failing stage; review them before sharing because they can include paths.

## Validation

The Windows CI job runs native PowerShell relay, upload preparation, and host
profile regression tests. To also exercise an installed Codex CLI locally, run
`python tool/test_windows_codex.py --dart path/to/dart.exe` after `flutter pub get`.
This optional test uses a temporary `CODEX_HOME`, starts and stops its own daemon,
and checks the WebSocket upgrade, initialization, and thread listing. It does not
send a prompt or read the user's existing Codex history. SSH authentication and
Android device testing are separate from this local transport smoke test.

To test the same Dart WebSocket/RPC client used by the mobile app against an
already-running local daemon, set `CODEX_TEST_SOCKET` to its exact `socketPath`:

```powershell
$env:CODEX_TEST_SOCKET = 'C:/Users/your-name/.codex/app-server-control/app-server-control.sock'
flutter test test/transport/windows_codex_integration_test.dart
```

This opt-in test only initializes a connection; it does not submit prompts or
query conversation history. The regular Windows CI suite also checks consecutive
interactive binary exchanges: a successful HTTP upgrade alone does not prove
that later RPC requests can pass through the Windows proxy.
