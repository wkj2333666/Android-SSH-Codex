#!/usr/bin/env bash
set -euo pipefail

# Flutter-OH adds TargetPlatform.ohos to the upstream enum. The pinned math
# renderer needs that case even though the app only uses non-selectable Math.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
math_root="${PUB_CACHE:-$HOME/.pub-cache}/hosted/pub.dev/flutter_math_fork-0.7.4"
math_patch="$script_dir/patches/flutter_math_fork_ohos.patch"
patch_args=(--directory="$math_root" --strip=1 --batch --fuzz=0 --input="$math_patch")

patch "${patch_args[@]}" --dry-run --forward
patch "${patch_args[@]}" --forward
# Leave the shared Pub cache in its original state, even on build failure.
trap 'patch "${patch_args[@]}" --reverse' EXIT

flutter build hap --release --no-codesign --target-platform ohos-arm64
