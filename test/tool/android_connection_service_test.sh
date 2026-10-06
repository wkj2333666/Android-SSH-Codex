#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/app/src/main"
printf '%s\n' '<manifest xmlns:android="http://schemas.android.com/apk/res/android">' '<application>' '</application>' '</manifest>' > "$fixture/app/src/main/AndroidManifest.xml"
bash "$repo_root/tool/configure_android_connection_service.sh" "$fixture"
cp "$fixture/app/src/main/AndroidManifest.xml" "$fixture/first.xml"
bash "$repo_root/tool/configure_android_connection_service.sh" "$fixture"
cmp "$fixture/first.xml" "$fixture/app/src/main/AndroidManifest.xml"
for permission in FOREGROUND_SERVICE FOREGROUND_SERVICE_SPECIAL_USE POST_NOTIFICATIONS WAKE_LOCK ACCESS_NETWORK_STATE; do
  grep -Fq "android.permission.$permission\"" "$fixture/first.xml"
done
grep -Fq 'android:exported="false"' "$fixture/first.xml"
grep -Fq 'android:stopWithTask="false"' "$fixture/first.xml"
cmp "$repo_root/tool/android/ConnectionRuntime.kt" "$fixture/app/src/main/kotlin/io/github/wkj2333666/android_ssh_codex/ConnectionRuntime.kt"
grep -Fq 'PROPERTY_SPECIAL_USE_FGS_SUBTYPE' "$fixture/first.xml"
cmp "$repo_root/tool/android/MainActivity.kt" "$fixture/app/src/main/kotlin/io/github/wkj2333666/android_ssh_codex/MainActivity.kt"
cmp "$repo_root/tool/android/ConnectionService.kt" "$fixture/app/src/main/kotlin/io/github/wkj2333666/android_ssh_codex/ConnectionService.kt"
test -s "$fixture/app/src/main/res/drawable/ic_connection.xml"
cmp "$repo_root/tool/android/DiagnosticLog.kt" "$fixture/app/src/main/kotlin/io/github/wkj2333666/android_ssh_codex/DiagnosticLog.kt"
cmp "$repo_root/tool/android/AttachmentPicker.kt" "$fixture/app/src/main/kotlin/io/github/wkj2333666/android_ssh_codex/AttachmentPicker.kt"
cmp "$repo_root/tool/android/AttachmentDownloads.kt" "$fixture/app/src/main/kotlin/io/github/wkj2333666/android_ssh_codex/AttachmentDownloads.kt"
cmp "$repo_root/tool/android/ConnectionDiagnostics.kt" "$fixture/app/src/main/kotlin/io/github/wkj2333666/android_ssh_codex/ConnectionDiagnostics.kt"
grep -Fq 'bash tool/configure_android_connection_service.sh' "$repo_root/tool/prepare_android.sh"
echo 'android_connection_service_test: PASS'
