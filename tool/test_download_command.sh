#!/usr/bin/env bash
set -euo pipefail
# Only used by the isolated loopback SSH regression fixture. Stall a selected
# data command while leaving metadata and subsequent downloads responsive.
case "$SSH_ORIGINAL_COMMAND" in
  *sha256sum*) exit 97 ;; # SFTP transfers must not depend on a remote hash command.
  *dd*stall-transfer*) sleep 35 ;;
esac
exec /bin/bash -c "$SSH_ORIGINAL_COMMAND"
