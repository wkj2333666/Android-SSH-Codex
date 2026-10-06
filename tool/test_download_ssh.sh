#!/usr/bin/env bash
set -euo pipefail

fixture=$(mktemp -d)
cleanup() {
  if [[ -f "$fixture/sshd.pid" ]]; then
    sudo kill "$(cat "$fixture/sshd.pid")" || true
  fi
  rm -r -- "$fixture"
}
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -f "$fixture/host"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/client"
sudo mkdir -p /run/sshd
# Supply configuration via stdin: only a loopback test listener, public-key
# authentication and the current CI user are allowed.
sudo /usr/sbin/sshd -f /dev/stdin <<EOF
Port 22229
ListenAddress 127.0.0.1
HostKey $fixture/host
PidFile $fixture/sshd.pid
AuthorizedKeysFile $fixture/client.pub
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
AllowUsers $(id -un)
ForceCommand /bin/bash $PWD/tool/test_download_command.sh
EOF
DOWNLOAD_TEST_KEY="$fixture/client" flutter test test/file_download_test.dart --reporter expanded
