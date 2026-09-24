#!/usr/bin/env python3
"""Check renamed build paths and resources; optionally inspect a packaged .app."""

import argparse
import json
import plistlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Lumora"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, help="Also validate a packaged Lumora.app")
args = parser.parse_args()


def require(path):
    if not path.is_file():
        raise SystemExit(f"Missing referenced file: {path}")


project = (ROOT / "Lumora.xcodeproj/project.pbxproj").read_text()
for setting in ("INFOPLIST_FILE", "CODE_SIGN_ENTITLEMENTS", "SWIFT_OBJC_BRIDGING_HEADER"):
    for value in re.findall(rf'\b{setting} = "?([^";]+)"?;', project):
        require(ROOT / value)

# Local Objective-C imports catch a renamed implementation with a stale header.
for path in SOURCE.rglob("*"):
    if path.suffix in (".h", ".mm", ".m"):
        for header in re.findall(r'^#import "([^"]+)"', path.read_text(), re.M):
            require(path.parent / header)

info = plistlib.loads((SOURCE / "Info.plist").read_bytes())
product = info["CFBundleName"]
scheme = ET.parse(ROOT / "Lumora.xcodeproj/xcshareddata/xcschemes/Lumora.xcscheme")
for ref in scheme.findall(".//BuildableReference"):
    if ref.attrib["BuildableName"].endswith(".app"):
        assert ref.attrib["BuildableName"] == f"{product}.app", "Scheme/app name mismatch"

icon_dir = SOURCE / "Assets.xcassets/AppIcon.appiconset"
for entry in json.loads((icon_dir / "Contents.json").read_text())["images"]:
    require(icon_dir / entry["filename"])

# Resource names are looked up dynamically at runtime, so a build may succeed
# even when a rename leaves the expected file missing from the application.
resources = SOURCE / "Resources"
resource_paths = []
for source in SOURCE.rglob("*.swift"):
    for name, extension in re.findall(
        r'Bundle\.main\.(?:url|path)\(forResource: "([^"\\]+)",\s*'
        r'(?:withExtension|ofType): "([^"\\]+)"', source.read_text()
    ):
        matches = list(resources.rglob(f"{name}.{extension}"))
        if not matches:
            raise SystemExit(f"Missing bundled resource {name}.{extension} ({source.name})")
        resource_paths.append(matches[0])

player = (SOURCE / "Core/NotificationSoundPlayer.swift").read_text()
if "NSSound(named: soundName)" not in player or "Bundle.main" in player:
    raise SystemExit("Notification sounds must use macOS named sounds, not bundled audio files")
if list((resources / "NotificationSounds").glob("*.aiff")):
    raise SystemExit("System alert audio must not be copied into the app bundle")

for path in resource_paths:
    require(path)

if args.app:
    contents = args.app.resolve() / "Contents"
    built = plistlib.loads((contents / "Info.plist").read_bytes())
    assert built["CFBundleName"] == product, "Packaged app name differs from source"
    require(contents / "MacOS" / built["CFBundleExecutable"])
    identifiers = set(re.findall(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);', project))
    assert built["CFBundleIdentifier"] in identifiers, "Packaged app identifier differs from project"
    bundled = contents / "Resources"
    require(bundled / "AppIcon.icns")
    for path in resource_paths:
        if not list(bundled.rglob(path.name)):
            raise SystemExit(f"Missing packaged resource: {path.name}")
    for language in ("en", "zh-Hans"):
        require(bundled / f"{language}.lproj/InfoPlist.strings")
        require(bundled / f"{language}.lproj/Localizable.strings")

print(f"Branding paths OK: Xcode inputs, scheme, icon assets, imports, {len(set(resource_paths))} runtime resources")
