#!/usr/bin/env bash
set -euo pipefail
android_root=${1:-android}
template_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/android" && pwd)
manifest="$android_root/app/src/main/AndroidManifest.xml"
for permission in FOREGROUND_SERVICE FOREGROUND_SERVICE_SPECIAL_USE POST_NOTIFICATIONS WAKE_LOCK ACCESS_NETWORK_STATE; do
  if ! grep -Fq "android.permission.$permission\"" "$manifest"; then
    sed -i "/<manifest/a\\    <uses-permission android:name=\"android.permission.$permission\" />" "$manifest"
  fi
done
if ! grep -Fq 'android:name=".ConnectionService"' "$manifest"; then
  sed -i '/<\/application>/i\        <service android:name=".ConnectionService" android:exported="false" android:stopWithTask="true" android:foregroundServiceType="specialUse">\n            <property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE" android:value="Maintains a user-initiated interactive SSH tunnel to a remote coding agent while switching apps." />\n        </service>' "$manifest"
fi
kotlin_dir="$android_root/app/src/main/kotlin/io/github/wkj2333666/android_ssh_codex"
mkdir -p "$kotlin_dir" "$android_root/app/src/main/res/drawable"
cp "$template_root/MainActivity.kt" "$template_root/ConnectionService.kt" "$template_root/DiagnosticLog.kt" "$kotlin_dir/"
cp "$template_root/AttachmentPicker.kt" "$kotlin_dir/"
cp "$template_root/ConnectionDiagnostics.kt" "$kotlin_dir/"
cp "$template_root/ic_connection.xml" "$android_root/app/src/main/res/drawable/"
