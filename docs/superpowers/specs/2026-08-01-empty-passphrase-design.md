# Empty Private-Key Passphrase Design

## Problem

The profile editor persists a blank key passphrase as the non-null string `""`.
The SSH connector passes that value to `SSHKeyPair.fromPem`. For unencrypted
OpenSSH and EC private keys, dartssh2 rejects every non-null passphrase,
including an empty string, with `Passphrase is not required for unencrypted
keys`.

## Design

Normalize optional passphrases at the SSH parsing boundary. `null`, the empty
string, and whitespace-only input become `null`; non-empty input remains exact
and is not trimmed before decryption. Both the target and ProxyJump connections
already share this boundary, so one normalization path fixes both without
changing persisted secrets.

The regression test exercises the boundary directly and verifies that blank
input reaches the key parser as `null`, while a real passphrase remains
unchanged. No private-key or passphrase value may be logged.

## Delivery

The fix ships with SSH `SetEnv` support on the `codex/ssh-setenv` branch. Red and
green verification run only in GitHub Actions; the Raspberry Pi workspace does
not run Flutter tests or builds.
