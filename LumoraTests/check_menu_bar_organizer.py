#!/usr/bin/env python3
"""Check Lumora's native menu-bar collision policy without touching AppKit UI."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
source = (repo / "Lumora/Services/System/MenuBarOrganizer.swift").read_text()
state_source = (repo / "Lumora/Services/System/MenuBarAvoidanceState.swift").read_text()
settings = (repo / "Lumora/UI/Views/MenuBarSettingsView.swift").read_text()

for obsolete in ("NSStatusBar", "NSStatusItem", "foldedLength", "autosaveName"):
    assert obsolete not in source, f"Legacy third-party organizer trace remains: {obsolete}"
assert "majorVersion >= 27" in source
assert "SystemMenuBarMonitor" in source
assert "MenuBarAvoidanceState" in source
assert "Automatic menu bar avoidance requires macOS 27 or later." in settings
assert "otherManagers" not in settings

harness = r'''
import Foundation

__STATE__

@main struct Check {
    static func main() {
        let protected = CGRect(x: 450, y: 970, width: 100, height: 30)
        let inside = CGRect(x: 520, y: 970, width: 20, height: 30)
        let edge = CGRect(x: 552, y: 970, width: 10, height: 30)
        let outside = CGRect(x: 700, y: 970, width: 20, height: 30)
        let start = Date(timeIntervalSince1970: 1_000)

        assert(MenuBarAvoidanceState.hasCollision(items: nil, protectedRect: protected))
        assert(MenuBarAvoidanceState.hasCollision(items: [], protectedRect: nil))
        assert(!MenuBarAvoidanceState.hasCollision(items: [], protectedRect: protected))
        assert(MenuBarAvoidanceState.hasCollision(items: [inside], protectedRect: protected))
        assert(MenuBarAvoidanceState.hasCollision(items: [edge], protectedRect: protected),
               "The four-point edge allowance must be retained")
        assert(!MenuBarAvoidanceState.hasCollision(items: [outside], protectedRect: protected))

        var state = MenuBarAvoidanceState()
        state.begin()
        assert(state.isYielding)
        assert(state.update(items: [], protectedRect: protected, now: start.addingTimeInterval(0.1)))
        assert(!state.update(items: [], protectedRect: protected, now: start.addingTimeInterval(0.41)),
               "Wait for stable clear space before restoring the panel")
        assert(state.update(items: [inside], protectedRect: protected, now: start.addingTimeInterval(0.42)))
        assert(state.update(items: [], protectedRect: protected, now: start.addingTimeInterval(0.5)))
        assert(!state.update(items: [], protectedRect: protected, now: start.addingTimeInterval(0.81)))
        state.stop()
        assert(!state.isYielding)
        print("PASS: native collision detection, edge tolerance, reflow settling, and reset")
    }
}
'''.replace("__STATE__", state_source)

sdk = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
if not sdk.exists():
    sdk = Path(subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip())
with tempfile.TemporaryDirectory(prefix="lumora-menu-bar-check-") as directory:
    directory = Path(directory)
    swift = directory / "check.swift"
    swift.write_text(harness)
    binary = directory / "check"
    subprocess.run([
        "swiftc", "-sdk", str(sdk), "-swift-version", "5", "-parse-as-library",
        "-module-cache-path", str(directory / "modules"), str(swift), "-o", str(binary)
    ], check=True)
    subprocess.run([str(binary)], check=True)
