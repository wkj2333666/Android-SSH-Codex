#!/usr/bin/env python3

import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ANDROID_NAMESPACE = "http://schemas.android.com/apk/res/android"
ANDROID_NAME = f"{{{ANDROID_NAMESPACE}}}name"
ANDROID_VALUE = f"{{{ANDROID_NAMESPACE}}}value"
IMPELLER_METADATA = "io.flutter.embedding.android.EnableImpeller"


def configure(manifest_path: Path) -> None:
    ET.register_namespace("android", ANDROID_NAMESPACE)
    tree = ET.parse(manifest_path)
    application = tree.getroot().find("application")
    if application is None:
        raise ValueError("Android manifest has no application element")

    entries = [
        entry
        for entry in application.findall("meta-data")
        if entry.get(ANDROID_NAME) == IMPELLER_METADATA
    ]
    if entries:
        impeller = entries[0]
        for duplicate in entries[1:]:
            application.remove(duplicate)
    else:
        impeller = ET.Element("meta-data")
        application.insert(0, impeller)

    impeller.set(ANDROID_NAME, IMPELLER_METADATA)
    impeller.set(ANDROID_VALUE, "false")

    temporary = manifest_path.with_suffix(f"{manifest_path.suffix}.tmp")
    tree.write(temporary, encoding="utf-8", xml_declaration=True)
    temporary.replace(manifest_path)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: configure_android_manifest.py MANIFEST", file=sys.stderr)
        return 2
    try:
        configure(Path(sys.argv[1]))
    except (OSError, ET.ParseError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
