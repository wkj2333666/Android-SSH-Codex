# HarmonyOS 4.2 Renderer Diagnostic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a single-variable Android diagnostic APK that renders with Skia instead of Impeller.

**Architecture:** The Android platform generation script calls an XML-aware normalizer that writes Flutter's documented `EnableImpeller=false` application metadata. Executable fixture tests lock insertion, replacement, duplicate removal, scope, and idempotence while GitHub Actions performs all tests and platform builds.

**Tech Stack:** Flutter 3.35.7, Android Manifest metadata, Flutter tests, GitHub Actions.

---

### Task 1: Prove the configuration is absent

**Files:**
- Create: `test/tool/configure_android_manifest_test.py`

- [x] Execute the Android Manifest normalizer against fixtures and assert that it produces one application-scoped `EnableImpeller=false` entry.
- [x] Push the test-only commit and confirm GitHub CI fails on the missing metadata.

### Task 2: Disable Impeller

**Files:**
- Modify: `tool/prepare_android.sh`
- Create: `tool/configure_android_manifest.py`
- Modify: `docs/BUILDING.md`
- Modify: `pubspec.yaml`

- [x] Normalize missing, enabled, or duplicate metadata to one disabled entry beneath the generated Android `<application>` element.
- [x] Document the HarmonyOS 4.x GPU compatibility fallback.
- [x] Set the diagnostic package version to `0.1.2+3`.

### Task 3: Verify and publish diagnostic

- [x] Confirm CI tests, Android APK/AAB, and OpenHarmony HAP builds pass remotely.
- [ ] Publish tag `v0.1.2-rc.1` as a GitHub prerelease.
- [ ] Compare the published APK checksum with `SHA256SUMS.txt`.
