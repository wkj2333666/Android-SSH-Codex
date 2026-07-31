import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ANDROID_NAMESPACE = "http://schemas.android.com/apk/res/android"
ANDROID_NAME = f"{{{ANDROID_NAMESPACE}}}name"
ANDROID_VALUE = f"{{{ANDROID_NAMESPACE}}}value"
IMPELLER_METADATA = "io.flutter.embedding.android.EnableImpeller"


class ConfigureAndroidManifestTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.manifest = Path(self.temp_dir.name) / "AndroidManifest.xml"
        self.write_manifest(("true",))

    def write_manifest(self, impeller_values):
        impeller_entries = "\n".join(
            f'    <meta-data android:name="{IMPELLER_METADATA}" android:value="{value}" />'
            for value in impeller_values
        )
        self.manifest.write_text(
            f"""<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="{ANDROID_NAMESPACE}">
  <application android:label="Android SSH Codex">
{impeller_entries}
    <meta-data android:name="example.setting" android:value="false" />
    <activity android:name=".MainActivity" />
    <activity android:name=".SecondaryActivity" />
  </application>
</manifest>
""",
            encoding="utf-8",
        )

    def impeller_entries(self):
        application = ET.parse(self.manifest).getroot().find("application")
        self.assertIsNotNone(application)
        return application, [
            entry
            for entry in application.findall("meta-data")
            if entry.get(ANDROID_NAME) == IMPELLER_METADATA
        ]

    def configure(self):
        return subprocess.run(
            [
                "python3",
                "tool/configure_android_manifest.py",
                str(self.manifest),
            ],
            capture_output=True,
            check=False,
            text=True,
        )

    def test_normalizes_one_application_scoped_impeller_entry(self):
        result = self.configure()
        self.assertEqual(result.returncode, 0, result.stderr)

        application, entries = self.impeller_entries()
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0].get(ANDROID_VALUE), "false")
        self.assertEqual(len(application.findall("activity")), 2)

    def test_inserts_missing_impeller_entry(self):
        self.write_manifest(())

        result = self.configure()
        self.assertEqual(result.returncode, 0, result.stderr)

        _, entries = self.impeller_entries()
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0].get(ANDROID_VALUE), "false")

    def test_removes_duplicate_impeller_entries(self):
        self.write_manifest(("true", "false", "true"))

        result = self.configure()
        self.assertEqual(result.returncode, 0, result.stderr)

        _, entries = self.impeller_entries()
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0].get(ANDROID_VALUE), "false")

    def test_configuration_is_idempotent(self):
        first_result = self.configure()
        self.assertEqual(first_result.returncode, 0, first_result.stderr)
        first = self.manifest.read_bytes()

        second_result = self.configure()
        self.assertEqual(second_result.returncode, 0, second_result.stderr)
        self.assertEqual(self.manifest.read_bytes(), first)


class ReleaseWorkflowTest(unittest.TestCase):
    def test_rc_tags_are_published_as_non_latest_prereleases(self):
        workflow = Path(".github/workflows/build.yml").read_text(encoding="utf-8")

        self.assertIn('[[ "$GITHUB_REF_NAME" == *-* ]]', workflow)
        self.assertIn("release_flags+=(--prerelease --latest=false)", workflow)
        self.assertIn('"${release_flags[@]}"', workflow)


if __name__ == "__main__":
    unittest.main()
