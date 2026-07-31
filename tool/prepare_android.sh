#!/usr/bin/env bash
set -euo pipefail

flutter create \
  --platforms=android \
  --org io.github.wkj2333666 \
  --project-name android_ssh_codex \
  .

manifest="android/app/src/main/AndroidManifest.xml"
if ! grep -q 'android.permission.INTERNET' "$manifest"; then
  sed -i '/<manifest/a\    <uses-permission android:name="android.permission.INTERNET" />' "$manifest"
fi
if ! grep -q 'android:allowBackup' "$manifest"; then
  sed -i '/<application/a\        android:allowBackup="false"' "$manifest"
fi
if ! grep -q 'io.flutter.embedding.android.EnableImpeller' "$manifest"; then
  sed -i '/<activity/i\        <meta-data android:name="io.flutter.embedding.android.EnableImpeller" android:value="false" />' "$manifest"
fi
sed -i 's/android:label="android_ssh_codex"/android:label="Android SSH Codex"/' "$manifest"

for gradle_file in android/app/build.gradle.kts android/app/build.gradle; do
  if [[ -f "$gradle_file" ]]; then
    sed -i \
      -e 's/minSdk = flutter.minSdkVersion/minSdk = 26/' \
      -e 's/minSdkVersion flutter.minSdkVersion/minSdkVersion 26/' \
      "$gradle_file"
  fi
done
