#!/usr/bin/env python3
"""Run with python3 scripts/check-localization.py (macOS Command Line Tools).

Checks catalog coverage and typed Foundation lookups without launching Lumora.
An Xcode build and visual checks are still needed for catalog compilation/layout.
"""

import json
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOKEN = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|(?:\.\d+)?[fg])")


def units(node):
    if isinstance(node, dict):
        if "stringUnit" in node:
            yield node["stringUnit"]["value"]
        for key, value in node.items():
            if key != "stringUnit":
                yield from units(value)


catalog = json.loads((ROOT / "Lumora/Localizable.xcstrings").read_text())
strings = catalog["strings"]
for filename in ("Localizable.xcstrings", "InfoPlist.xcstrings"):
    data = json.loads((ROOT / "Lumora" / filename).read_text())
    assert data["sourceLanguage"] == "en"
    for key, entry in data["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        translated = list(units(entry["localizations"]["zh-Hans"]))
        assert translated, f"Missing Chinese: {filename}: {key}"
        for value in translated:
            assert value.strip(), f"Empty Chinese: {key}"
            assert sorted(TOKEN.findall(key)) == sorted(TOKEN.findall(value)), key

for source in (ROOT / "Lumora").rglob("*.swift"):
    for key in re.findall(r'String\(localized:\s*"([^"\\]+)"', source.read_text()):
        assert key in strings, f"Missing catalog key: {source.name}: {key}"

for key in ("Found %lld files", "%lld lines"):
    plural = strings[key]["localizations"]["en"]["variations"]["plural"]
    assert {"one", "other"} <= plural.keys(), f"Missing English plurals: {key}"

# Language-specific test bundles avoid depending on the developer's UI language.
# The Swift calls exercise real typed interpolation against our catalog keys.
with tempfile.TemporaryDirectory(prefix="lumora-localization-") as temp:
    folder = Path(temp)
    for language in ("en", "zh-Hans"):
        bundle = folder / f"{language}.lproj"
        bundle.mkdir()
        values = {}
        for key, entry in strings.items():
            localized = entry.get("localizations", {}).get(language, {})
            values[key] = localized.get("stringUnit", {}).get("value", key)
        (bundle / "Localizable.strings").write_bytes(plistlib.dumps(values))

    swift = r'''import Foundation
let root = CommandLine.arguments[1]
let zh = Bundle(path: root + "/zh-Hans.lproj")!
let en = Bundle(path: root + "/en.lproj")!
let tool = "exec_command"
let seconds = 12
let keyCode = 9
let checks: [(String, String)] = [
    (String(localized: "Back", bundle: zh), "返回"),
    (String(localized: "Waiting for approval: \(tool)", bundle: zh), "等待授权：exec_command"),
    (String(localized: "\(seconds)s", bundle: zh), "12秒"),
    (String(localized: "Key\(keyCode)", bundle: zh), "按键 9"),
    (String(localized: "Back", bundle: en), "Back"),
]
for (actual, expected) in checks {
    guard actual == expected else {
        print("Localization mismatch: \(actual) != \(expected)")
        exit(1)
    }
}
'''
    source = folder / "check.swift"
    source.write_text(swift)
    subprocess.run(["xcrun", "swift", str(source), str(folder)], check=True)

print(f"Localization OK: {len(strings)} keys, Chinese coverage, English plurals, typed lookups")
