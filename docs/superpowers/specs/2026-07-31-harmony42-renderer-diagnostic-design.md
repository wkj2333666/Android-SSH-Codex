# HarmonyOS 4.2 Renderer Diagnostic Design

## Evidence

The v0.1.1 application renders its widget tree before secure-storage
initialization and catches storage failures, but the affected HarmonyOS 4.2
device still remains on a black launch surface. Flutter 3.35 enables Impeller
on Android by default. Flutter's official tracker contains Huawei-device black
screens that disappear when Impeller is disabled, as well as Impeller GLES and
Vulkan failures in the 3.35 release line.

## Hypothesis

The device GPU driver cannot render the first Flutter frame through the
selected Impeller backend. Disabling Impeller should select Skia and allow the
same Dart application to render.

## Diagnostic Change

Add `io.flutter.embedding.android.EnableImpeller=false` to the generated
Android application manifest. Do not change Flutter, dependencies, startup
logic, or UI code. Build a prerelease APK through GitHub Actions so the target
device can test this single variable.

If the prerelease remains black, do not make another renderer change without
capturing `adb logcat` from the target device.
