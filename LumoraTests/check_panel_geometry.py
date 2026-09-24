#!/usr/bin/env python3
"""Check production panel geometry and AppKit hit testing in unshown windows.

Requires macOS Command Line Tools. No running Lumora instance is controlled.
The app model/content are stubbed; the actual presentation reader, animation
contract, interaction-size property, geometry and AppKit controller are compiled.
The native SwiftUI shell mirrors the production reader-after-frame placement;
this checks real intermediate geometry, not visible screen frame rate.
"""
import pathlib
import re
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[1]
sdk = pathlib.Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
if not sdk.exists():
    sdk = pathlib.Path(subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip())
window_source = (repo / "Lumora/UI/Window/NotchWindowController.swift").read_text()
provider = re.search(
    r"(?ms)contentTypeProvider = \{ \[weak viewModel\] in\n(.*?)^        }", window_source
)
assert provider, "Cannot find production shortcut content provider"
vm_source = (repo / "Lumora/Core/NotchViewModel.swift").read_text()
interaction = re.search(r"(?ms)^    var interactionSize: CGSize \{\n.*?^    }", vm_source)
assert interaction, "Cannot find production interaction size"
view_source = (repo / "Lumora/UI/Views/NotchView.swift").read_text()
reader_frame = re.search(
    r"(?m)^            \.frame\(width: notchSize.width, height: notchSize.height, alignment: \.top\)\n"
    r"            \.background\(PanelPresentationReader\(presentation: viewModel.panelPresentation\)\.allowsHitTesting\(false\)\)",
    view_source,
)
assert reader_frame, "The reader must measure the animated panel frame, not its outer container"

harness = r'''
import AppKit
import SwiftUI

enum NotchStatus { case closed, opened, popping }
enum Content { case instances, chat }
struct ExpandingActivity: Equatable { static let empty = Self() }
@MainActor final class NotchViewModel: ObservableObject {
    let geometry: NotchGeometry
    @Published var status = NotchStatus.opened
    var isClosing = false
    let panelPresentation = PanelPresentation()
__INTERACTION__
    var openedSize = CGSize(width: 480, height: 228)
    var closedNotchExpansionWidth: CGFloat = 70
    var contentType = Content.chat
    init(geometry: NotchGeometry) { self.geometry = geometry }
}
struct NotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    var body: some View {
        let size = viewModel.status == .opened ? viewModel.openedSize
            : viewModel.geometry.closedPanelSize(expansionWidth: viewModel.closedNotchExpansionWidth)
        Color.blue
__READER_FRAME__
            .panelAnimationContract(inputs: PanelAnimationInputs(
                notchSize: size, status: viewModel.status, expandingActivity: .empty,
                hasPendingPermission: false, hasWaitingForInput: false, showMusicActivity: false,
                vibeGlowEnabled: false, notchAppearanceStyleRaw: "music", artworkData: nil, isBouncing: false
            ), reduceMotion: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
@MainActor func shortcutContentType(_ viewModel: NotchViewModel?) -> Content {
    __PROVIDER__
}

func checkRect(_ actual: CGRect, _ expected: CGRect, _ message: String) {
    let deltas = [actual.minX - expected.minX, actual.minY - expected.minY,
                  actual.width - expected.width, actual.height - expected.height]
    precondition(deltas.allSatisfy { abs($0) < 0.01 }, "\(message): \(actual) != \(expected)")
}

@main struct GeometryCheck {
@MainActor static func main() {
_ = NSApplication.shared
// Main display, a display to its left, and one above it. The windows are never shown.
for screen in [CGRect(x: 0, y: 0, width: 1470, height: 956),
               CGRect(x: -1920, y: 160, width: 1920, height: 1080),
               CGRect(x: 320, y: 956, width: 1920, height: 1080)] {
    for notchHeight: CGFloat in [0, 32] {
        let geometry = NotchGeometry(
            deviceNotchRect: CGRect(x: (screen.width - 180) / 2, y: 0,
                                   width: 180, height: notchHeight),
            screenRect: screen, windowHeight: 750
        )
        let vm = NotchViewModel(geometry: geometry)
        let frame = CGRect(x: screen.minX, y: screen.maxY - 750,
                           width: screen.width, height: 750)
        let window = NSWindow(contentRect: frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NotchViewController(viewModel: vm)
        window.contentViewController = controller
        window.setFrame(frame, display: false)
        let host = controller.view as! PassThroughHostingView<NotchView>
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.layoutSubtreeIfNeeded()
        precondition(host.isFlipped, "This check must exercise SwiftUI's flipped hosting view")

        for status in [NotchStatus.opened, .closed, .popping] {
            vm.status = status
            precondition(shortcutContentType(vm) == (status == .opened ? .chat : .instances),
                         "Closed panels must not consume chat-only keyboard shortcuts")
            let size = status == .opened ? vm.openedSize
                : geometry.closedPanelSize(expansionWidth: vm.closedNotchExpansionWidth)
            let expected = CGRect(x: (screen.width - size.width) / 2,
                                  y: 0, width: size.width, height: size.height)
            checkRect(host.hitTestRect(), expected, "Panel hit area must start at the top")
            let outside = host.convert(CGPoint(x: expected.midX, y: expected.maxY + 1), to: host.superview)
            precondition(host.hitTest(outside) == nil,
                         "Clicks below the panel must pass through")
        }

        vm.status = .opened
        let panel = geometry.openedScreenRect(for: vm.openedSize)
        for local in [CGPoint(x: vm.openedSize.width / 2, y: vm.openedSize.height - 1),
                      CGPoint(x: 1, y: 40), CGPoint(x: vm.openedSize.width - 1, y: 40)] {
            let point = CGPoint(x: panel.minX + local.x, y: screen.maxY - local.y)
            precondition(geometry.isPointInOpenedPanel(point, size: vm.openedSize),
                         "Visible bottom and side controls must count as inside")
            precondition(!geometry.isPointOutsidePanel(point, size: vm.openedSize),
                         "Clicking a visible control must not close the panel")
            let windowPoint = window.convertPoint(fromScreen: point)
            let hostPoint = host.convert(windowPoint, from: nil)
            precondition(host.hitTestRect().contains(hostPoint),
                         "Screen event and hosting hit test must agree")
            let parentPoint = host.convert(hostPoint, to: host.superview)
            precondition(host.hitTest(parentPoint) != nil,
                         "Native hitTest receives a point in the superview coordinate system")
            let parent = host.superview!
            let hit = parent.hitTest(parent.convert(parentPoint, to: parent.superview))
            precondition(hit === host || hit?.isDescendant(of: host) == true,
                         "AppKit must route a visible panel click into the hosting view")
        }
        precondition(geometry.isPointOutsidePanel(
            CGPoint(x: panel.midX, y: panel.minY - 1), size: vm.openedSize))
        let closedSize = geometry.closedPanelSize(expansionWidth: 70)
        precondition(closedSize == CGSize(width: 274, height: max(24, notchHeight)))
        if notchHeight == 32 {
            func flush(_ seconds: TimeInterval = 0.04) {
                host.layoutSubtreeIfNeeded()
                CATransaction.flush()
                RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            }
            flush(0.35)
            precondition(vm.panelPresentation.size == vm.openedSize)
            vm.isClosing = true
            vm.status = .closed
            var previousSize = vm.openedSize
            for _ in 0..<4 {
                flush()
                let reader = vm.panelPresentation.view!
                let presented = vm.panelPresentation.size!
                precondition(presented.width > closedSize.width && presented.width < previousSize.width,
                    "Closing interaction width jumped to its target or stopped following the animation")
                precondition(presented.height > closedSize.height && presented.height < previousSize.height,
                    "Closing interaction height jumped to its target or stopped following the animation")
                // Current SwiftUI frame animations update this view's actual
                // bounds. A future transform-based layout needs a new reader.
                precondition(CATransform3DIsIdentity(reader.layer!.presentation()!.transform))
                let nativeFrame = reader.convert(reader.bounds, to: host)
                checkRect(nativeFrame, CGRect(x: (screen.width - presented.width) / 2,
                    y: 0, width: presented.width, height: presented.height),
                    "Reader bounds must match the actual centered AppKit frame")
                checkRect(host.hitTestRect(), nativeFrame,
                    "Controller hit area must follow the currently drawn panel")
                let inside = CGPoint(x: nativeFrame.midX,
                    y: (closedSize.height + nativeFrame.maxY) / 2)
                precondition(host.hitTest(host.convert(inside, to: host.superview)) != nil,
                    "Visible closing content must still accept a return click")
                let outside = CGPoint(x: nativeFrame.midX, y: nativeFrame.maxY + 1)
                precondition(host.hitTest(host.convert(outside, to: host.superview)) == nil,
                    "The part already collapsed must pass clicks through")
                previousSize = presented
            }
            flush(PanelMotion.closeSpring.settlingDuration + 0.05)
            checkRect(host.hitTestRect(), CGRect(x: (screen.width - closedSize.width) / 2,
                y: 0, width: closedSize.width, height: closedSize.height),
                "The close must settle at the compact hit area")
            vm.isClosing = false
        }
        window.contentViewController = nil
        window.close()
    }
}
print("PASS: native closing presentation and AppKit hit areas agree; static geometry covers 3 display origins with and without a notch")
}
}
'''.replace("__PROVIDER__", provider.group(1)).replace("__INTERACTION__", interaction.group(0)).replace("__READER_FRAME__", reader_frame.group(0).replace("notchSize", "size"))

with tempfile.TemporaryDirectory(prefix="lumora-geometry-check-") as temporary:
    directory = pathlib.Path(temporary)
    main = directory / "main.swift"
    main.write_text(harness)
    executable = directory / "check"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-default-isolation", "MainActor", "-sdk", str(sdk),
        str(repo / "Lumora/Core/NotchGeometry.swift"),
        str(repo / "Lumora/UI/Components/PanelAnimationContract.swift"),
        str(repo / "Lumora/Core/Animation+Settings.swift"),
        str(repo / "Lumora/UI/Window/NotchViewController.swift"),
        str(main), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)
