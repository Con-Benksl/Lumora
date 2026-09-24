#!/usr/bin/env python3
"""Run the production list metric sync with empty and real layout measurements."""
import pathlib
import re
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[1]
source = (repo / "Lumora/UI/Views/SessionListView.swift").read_text()
match = re.search(r"(?ms)^    func syncLayoutMetrics\(\) \{.*?^    }$", source)
assert match, "Cannot find production syncLayoutMetrics"
model_source = (repo / "Lumora/Core/NotchViewModel.swift").read_text()
height_blocks = []
for declaration in (
    r"private enum InstancesPageLayout",
    r"private var instancesPageOpenedHeight: CGFloat",
    r"private var resolvedRowHeight: CGFloat",
    r"private var resolvedMusicCardHeight: CGFloat",
    r"private var resolvedPerformanceRowHeight: CGFloat",
    r"private func listHeight\(rowHeight: CGFloat, visibleRows: CGFloat\) -> CGFloat",
):
    block = re.search(r"(?ms)^    " + declaration + r" \{.*?^    }$", model_source)
    assert block, f"Cannot find production height calculation: {declaration}"
    height_blocks.append(block.group())
layout_source = (repo / "Lumora/UI/Components/SettingsPageLayout.swift").read_text()
header = re.search(r"(?ms)^func settingsPageHeaderHeight\(.*?^}$", layout_source)
assert header, "Cannot find production header height helper"
harness = r'''
import Foundation
enum Content { case instances, menu }
final class Model {
    var contentType = Content.instances
    var instancesPageRowHeight: CGFloat = 64
    var instancesPagePerformanceRowHeight: CGFloat = 48
    var instancesPageMusicCardHeight: CGFloat = 124
    var heights: [CGFloat] {
        [instancesPageRowHeight, instancesPagePerformanceRowHeight, instancesPageMusicCardHeight]
    }
}
struct List {
    let viewModel = Model()
    var instanceRowHeight: CGFloat = 0
    var performanceRowHeight: CGFloat = 0
    var musicCardHeight: CGFloat = 0
    __METHOD__
}
var list = List()
list.syncLayoutMetrics()
precondition(list.viewModel.heights == [64, 48, 124], "Reopening before layout must preserve cached sizes")
list.instanceRowHeight = 68
list.performanceRowHeight = 52
list.musicCardHeight = 130
list.syncLayoutMetrics()
precondition(list.viewModel.heights == [68, 52, 130], "Real size changes must still apply")
list.instanceRowHeight = -1
list.performanceRowHeight = 0
list.musicCardHeight = 130.25
list.syncLayoutMetrics()
precondition(list.viewModel.heights == [68, 52, 130], "Empty and subpixel measurements must not resize the panel")
list.viewModel.contentType = .menu
list.instanceRowHeight = 72
list.syncLayoutMetrics()
precondition(list.viewModel.heights == [68, 52, 130], "A disappearing list must not resize another page")
print("PASS: list reopening preserves measured sizes and accepts real layout changes")

__GEOMETRY__
__HEADER__
struct HeightModel {
    let geometry: NotchGeometry
    var instancesPageSessionCount = 0
    var instancesPageShowsPerformance = false
    var instancesPageShowsMusic = false
    var instancesPageRowHeight: CGFloat = 0
    var instancesPagePerformanceRowHeight: CGFloat = 0
    var instancesPageMusicCardHeight: CGFloat = 0
    __HEIGHT_BLOCKS__
    var height: CGFloat { instancesPageOpenedHeight }
}
for notchHeight: CGFloat in [0, 32] {
    var model = HeightModel(geometry: NotchGeometry(
        deviceNotchRect: CGRect(x: 0, y: 0, width: 180, height: notchHeight),
        screenRect: CGRect(x: 0, y: 0, width: 1470, height: 956), windowHeight: 750
    ))
    // Expected rendered chrome: 24/32pt header plus 12pt bottom padding.
    let chrome: CGFloat = notchHeight == 0 ? 36 : 44
    precondition(model.height == chrome + 84, "Empty state must fit below the real header")
    model.instancesPageShowsPerformance = true
    precondition(model.height == chrome + 44 + 8 + 84, "Performance row must not clip the bottom")
    model.instancesPageShowsMusic = true
    precondition(model.height == chrome + 44 + 8 + 108 + 8 + 84, "Music needs its own height and spacing")
    model.instancesPageSessionCount = 1
    precondition(model.height == chrome + 44 + 8 + 108 + 8 + 58, "One session replaces the empty state")
    model.instancesPageSessionCount = 8
    precondition(abs(model.height - (chrome + 44 + 8 + 108 + 8 + 191.6)) < 0.01,
                 "Long lists show 3.2 rows plus three 2pt gaps")
    model.instancesPageRowHeight = 70
    model.instancesPagePerformanceRowHeight = 50
    model.instancesPageMusicCardHeight = 130
    precondition(model.height == chrome + 58 + 138 + 230, "Measured rows must size the expanded panel")
    model.instancesPageShowsPerformance = false
    model.instancesPageShowsMusic = false
    model.instancesPageSessionCount = 1
    precondition(model.height == chrome + 70, "Hidden cards must not add their cached heights")
}
print("PASS: production instances height includes the real header, bottom padding, cards, and capped session list")
'''.replace("__METHOD__", match.group()).replace(
    "__GEOMETRY__", (repo / "Lumora/Core/NotchGeometry.swift").read_text()
).replace("__HEADER__", header.group()).replace("__HEIGHT_BLOCKS__", "\n".join(height_blocks))

with tempfile.TemporaryDirectory(prefix="lumora-list-layout-check-") as temporary:
    swift = pathlib.Path(temporary) / "main.swift"
    swift.write_text(harness)
    subprocess.run(["xcrun", "swift", str(swift)], check=True)
