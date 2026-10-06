#!/usr/bin/env bash
set -euo pipefail
# Only used by the isolated loopback SSH regression fixture. Stall a selected
# data command while leaving metadata and subsequent downloads responsive.
case "$SSH_ORIGINAL_COMMAND" in
  *dd*stall-transfer*) sleep 35 ;;
esac
exec /bin/bash -c "$SSH_ORIGINAL_COMMAND"
