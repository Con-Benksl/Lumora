#!/usr/bin/env python3
"""Render the production controls offscreen and inspect real SwiftUI transactions.

Requires macOS and a SwiftUI-capable SDK. Override LUMORA_SWIFT_SDK when needed.
No Lumora process, on-screen window, accessibility permission or user setting changes.
Only unrelated model metadata is stubbed; views and animation modifiers are compiled
from the repository. The native controls use the current OS motion preference;
the panel contract is exercised with both explicit reduced-motion input values.
The close spring uses Apple's native samples; reduced-motion content transitions
exercise real insertion/removal. Close completions use unshown native windows with
the per-value contract and a plain-panel control, covering normal and reduced motion.
This checks native lifecycle and intermediate geometry, not visible frame rate.
The spectrum check injects only the read-only OS motion value into a temporary
source copy; its actual NSViewRepresentable, Timer and CALayers remain unchanged.
"""
import os
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[1]
sdk = os.environ.get("LUMORA_SWIFT_SDK", "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
if not pathlib.Path(sdk).exists():
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
sources = [
    "Lumora/UI/Components/ButtonStyles.swift",
    "Lumora/UI/Components/ActionButton.swift",
    "Lumora/UI/Components/ExpandableSettingsRow.swift",
    "Lumora/UI/Components/ExpandableContent.swift",
    "Lumora/UI/Components/ProcessingSpinner.swift",
    "Lumora/UI/Components/PanelAnimationContract.swift",
    "Lumora/UI/Components/TerminalColors.swift",
    "Lumora/Core/Animation+Settings.swift",
    "Lumora/Models/SessionProvider.swift",
]

harness = r'''
import AppKit
import SwiftUI
import Combine

enum NotchStatus: Equatable { case closed, opened, popping }
struct ExpandingActivity: Equatable { static let empty = Self() }
struct PlaybackState {
    var title = "", artist = "", album = ""
    var isPlaying = false
}
final class MusicManager: ObservableObject {
    var playbackState = PlaybackState()
    var albumArt: NSImage?
    var artworkGradient: [NSColor] = []
}
final class Model: ObservableObject {
    @Published var inputs = PanelAnimationInputs(notchSize: CGSize(width: 180, height: 32), status: .closed, expandingActivity: .empty, hasPendingPermission: false, hasWaitingForInput: false, showMusicActivity: false, vibeGlowEnabled: false, notchAppearanceStyleRaw: "music", artworkData: nil, isBouncing: false)
    var reduceMotion = false
    var captured: [Animation?] = []
    let presentation = PanelPresentation()
}
struct Probe: NSViewRepresentable {
    let inputs: PanelAnimationInputs
    let capture: (Animation?) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) { capture(context.transaction.animation) }
}
struct Panel: View {
    @ObservedObject var model: Model
    var body: some View {
        Probe(inputs: model.inputs, capture: { model.captured.append($0) })
            .frame(width: model.inputs.notchSize.width, height: model.inputs.notchSize.height)
            .background(PanelPresentationReader(presentation: model.presentation).allowsHitTesting(false))
            .panelAnimationContract(inputs: model.inputs, reduceMotion: model.reduceMotion)
    }
}
@main
struct Check {
    @MainActor static func main() {
        _ = NSApplication.shared
        checkCompactSpectrumMotion()
        checkPanelTransitions()
        checkPanelCloseCompletion()

        for expanded in [false, true] {
            let content = ExpandableContent(isExpanded: expanded, targetHeight: 120) {
                Color.white.frame(height: 120)
            }
            let host = NSHostingView(rootView: content)
            let height = host.fittingSize.height
            precondition(abs(height - (expanded ? 120 : 0)) < 0.1, "picker height \(height)")
        }
        let plain = SettingsSubPickerRow(label: "中文菜单", isSelected: false) {}
        let selected = SettingsSubPickerRow(label: "中文菜单", isSelected: true) {}
        precondition(abs(NSHostingView(rootView: plain).fittingSize.height - NSHostingView(rootView: selected).fittingSize.height) < 0.1)
        for provider in SessionProvider.allCases {
            let spinner = ProcessingSpinner(provider: provider)
            precondition(NSHostingView(rootView: spinner).fittingSize.width == 16)
            let loading = SessionLoadingRow(provider: provider, turnId: "sample")
            precondition(NSHostingView(rootView: loading).fittingSize.height > 0)
        }
        let model = Model()
        let host = NSHostingView(rootView: Panel(model: model))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 700)
        func flush() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.06)); host.layoutSubtreeIfNeeded() }
        flush()
        func verify(_ name: String, _ expected: Animation?, _ mutate: () -> Void) {
            model.captured.removeAll()
            mutate(); flush()
            precondition(!model.captured.isEmpty, "no real SwiftUI transaction")
            precondition(model.captured.allSatisfy { $0 == expected }, "wrong animation: \(name)")
        }
        verify("open", .panelOpen) {
            model.inputs.status = .opened
            model.inputs.notchSize = CGSize(width: 460, height: 300)
        }
        verify("picker", .settingsExpand) { model.inputs.notchSize.height = 420 }
        verify("close", .panelClose) {
            model.inputs.status = .closed
            model.inputs.notchSize = CGSize(width: 180, height: 32)
        }
        // Each change interrupts the previous animation before it finishes.
        for _ in 0..<4 {
            verify("interrupted open", .panelOpen) {
                model.inputs.status = .opened
                model.inputs.notchSize = CGSize(width: 460, height: 300)
            }
            verify("interrupted close", .panelClose) {
                model.inputs.status = .closed
                model.inputs.notchSize = CGSize(width: 180, height: 32)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        precondition(model.inputs.status == .closed)
        precondition(host.fittingSize == CGSize(width: 180, height: 32), "interrupted panel did not settle")
        model.reduceMotion = true
        verify("reduced", nil) {
            model.inputs.status = .opened
            model.inputs.notchSize = CGSize(width: 460, height: 300)
        }
        print("PASS: native geometry; panel transactions, close spring and completion; reduced-motion transition lifecycle; spectrum motion and teardown")
    }
}

'''
transition_check = r'''
final class TransitionState: ObservableObject {
    @Published var expanded = false
    var live = Set<String>()
}
struct TransitionProbe: NSViewRepresentable {
    let name: String
    let state: TransitionState
    final class Coordinator {
        let name: String
        let state: TransitionState
        init(_ name: String, _ state: TransitionState) { self.name = name; self.state = state }
    }
    func makeCoordinator() -> Coordinator { Coordinator(name, state) }
    func makeNSView(context: Context) -> NSView {
        state.live.insert(name)
        return NSView()
    }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.state.live.remove(coordinator.name)
    }
}
struct TransitionPanel: View {
    @ObservedObject var state: TransitionState
    var body: some View {
        ZStack {
            if state.expanded {
                TransitionProbe(name: "content", state: state)
                    .transition(.panelContent(reduceMotion: true))
            } else {
                TransitionProbe(name: "compact", state: state)
                    .transition(.panelCompact(reduceMotion: true))
            }
        }
    }
}
@MainActor func checkPanelTransitions() {
    // Sample Apple's actual spring, not a copied easing formula. A close must
    // approach its endpoint without reversing or overshooting the notch.
    let spring = PanelMotion.closeSpring
    var previous = 0.0
    for step in 0...240 {
        let value = spring.value(target: 1.0, time: spring.settlingDuration * Double(step) / 240)
        precondition(value >= previous - 0.000001 && value <= 1.000001, "close spring rebounds")
        previous = value
    }
    precondition(abs(previous - 1) < 0.001, "close spring cut off before settling")

    // Unshown hosts do not tick visible animation frames. Identity transitions
    // DO have an observable native lifecycle: no outgoing content may linger,
    // even during rapid reversals with the reduced-motion setting.
    let state = TransitionState()
    let host = NSHostingView(rootView: TransitionPanel(state: state))
    host.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
    for step in 0..<9 {
        state.expanded = step % 2 == 1
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        host.layoutSubtreeIfNeeded()
        precondition(state.live == [state.expanded ? "content" : "compact"],
                     "reduced-motion transition retained outgoing content")
    }
}

struct PlainPanel: View {
    @ObservedObject var model: Model
    var body: some View {
        Probe(inputs: model.inputs, capture: { model.captured.append($0) })
            .frame(width: model.inputs.notchSize.width, height: model.inputs.notchSize.height)
            .background(PanelPresentationReader(presentation: model.presentation).allowsHitTesting(false))
    }
}
@MainActor func checkPanelCloseCompletion() {
    func run<V: View>(reduced: Bool, outerAnimation: Animation?, content: (Model) -> V) -> Bool {
        let model = Model()
        model.reduceMotion = reduced
        model.inputs.status = .opened
        model.inputs.notchSize = CGSize(width: 460, height: 300)
        let host = NSHostingView(rootView: content(model))
        let frame = CGRect(x: 0, y: 0, width: 600, height: 700)
        // A detached NSHostingView freezes animation frames. Attaching it to an
        // unshown native window exercises the real layer lifecycle without UI automation.
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrame(frame, display: false)
        host.frame = frame
        defer { window.contentView = nil; window.close() }
        func flush() {
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
        }
        flush()
        precondition(model.presentation.size == model.inputs.notchSize,
                     "presentation reader must follow the rendered panel")
        model.captured.removeAll()
        var completions = 0
        withAnimation(outerAnimation, completionCriteria: .removed) {
            model.inputs.status = .closed
            model.inputs.notchSize = CGSize(width: 180, height: 32)
        } completion: {
            completions += 1
        }
        let deadline = Date().addingTimeInterval(1.5)
        var sawIntermediate = false
        repeat {
            flush()
            if let size = model.presentation.size, size.height > 32.1 && size.height < 299.9 {
                sawIntermediate = true
                precondition(completions == 0, "close completion must wait for the rendered spring")
            }
        } while completions == 0 && Date() < deadline
        precondition(completions == 1, "native close completion must fire")
        precondition(reduced || sawIntermediate, "normal close must exercise actual intermediate animation frames")
        precondition(model.presentation.size == model.inputs.notchSize,
                     "completed close must expose the settled presentation size")
        precondition(!model.captured.isEmpty && model.captured.allSatisfy { $0 == (reduced ? nil : .panelClose) },
                     "completion test must exercise the real close animation")
        flush()
        precondition(completions <= 1, "close completion must fire at most once")
        return completions == 1
    }
    let baselineCompletes = run(reduced: false, outerAnimation: .panelClose) { PlainPanel(model: $0) }
    for reduced in [false, true] {
        for outerAnimation: Animation? in [.panelClose, nil] {
            let completes = run(reduced: reduced, outerAnimation: outerAnimation) { Panel(model: $0) }
            if !reduced {
                precondition(completes == baselineCompletes,
                             "per-value contract must preserve the native host's completion behavior")
            }
        }
    }
    precondition(baselineCompletes, "native plain-panel animation control must complete")
}

'''
spectrum_check = r'''
private extension CompactAudioSpectrum {
    func checkAnimationState(timer: Bool, animated: Bool, stage: String = "") {
        precondition((animationTimer != nil) == timer, "spectrum timer state")
        let activeLayers = barLayers + [gradientLayer]
        precondition(activeLayers.contains { !($0.animationKeys() ?? []).isEmpty } == animated,
                     "spectrum layer animation state \(stage) expected \(animated), keys \(activeLayers.map { $0.animationKeys() ?? [] })")
    }
}

@MainActor
func checkCompactSpectrumMotion() {
    func find(_ view: NSView) -> CompactAudioSpectrum? {
        if let spectrum = view as? CompactAudioSpectrum { return spectrum }
        return view.subviews.lazy.compactMap { find($0) }.first
    }
    for levels: [Float]? in [nil, [0.2, 0.4, 0.8, 0.5]] {
        func content(reduced: Bool) -> AnyView {
            AnyView(CompactAudioSpectrumView(isPlaying: true, gradientColors: [],
                                            realSpectrumLevels: levels, reduceMotion: reduced))
        }
        let host = NSHostingView(rootView: content(reduced: false))
        host.frame = CGRect(x: 0, y: 0, width: 16, height: 14)
        func flush() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
        }
        flush()
        guard let spectrum = find(host) else { preconditionFailure("native spectrum missing") }
        // A real-band animation lasts only 80ms; feed the next frame and inspect
        // it immediately so startup/layout work cannot outlast the assertion.
        if levels != nil { spectrum.setRealSpectrumLevels([0.9, 0.7, 0.4, 0.2]) }
        spectrum.checkAnimationState(timer: levels == nil, animated: true, stage: "normal \(String(describing: levels))")
        host.rootView = content(reduced: true)
        flush()
        spectrum.checkAnimationState(timer: false, animated: false)
        host.rootView = content(reduced: false)
        flush()
        // A real-band animation lasts only 80ms; feed the next frame and inspect
        // it immediately so startup/layout work cannot outlast the assertion.
        if levels != nil { spectrum.setRealSpectrumLevels([0.9, 0.7, 0.4, 0.2]) }
        spectrum.checkAnimationState(timer: levels == nil, animated: true, stage: "normal \(String(describing: levels))")
        // Replacing the representable exercises SwiftUI's actual dismantle callback.
        host.rootView = AnyView(EmptyView())
        flush()
        spectrum.checkAnimationState(timer: false, animated: false)
    }
}
'''
with tempfile.TemporaryDirectory(prefix="lumora-native-controls-") as temporary:
    directory = pathlib.Path(temporary)
    main = directory / "Check.swift"
    main.write_text(harness + transition_check)
    spectrum = directory / "CompactMusicActivityView.swift"
    spectrum_source = (repo / "Lumora/UI/Components/CompactMusicActivityView.swift").read_text()
    motion_property = r"@Environment(\.accessibilityReduceMotion) private var reduceMotion"
    assert spectrum_source.count(motion_property) == 1
    spectrum.write_text(spectrum_source.replace(motion_property, "var reduceMotion = false") + spectrum_check)
    executable = directory / "check"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
        "-sdk", sdk, "-o", str(executable), str(main), str(spectrum),
        *[str(repo / source) for source in sources],
    ], check=True)
    subprocess.run([str(executable)], check=True)
