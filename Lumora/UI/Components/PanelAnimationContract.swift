import AppKit
import SwiftUI

enum PanelMotion {
    static let closeSpring = Spring(duration: 0.38, bounce: 0)
}

/// Read the rendered layer on demand, never feed measured sizes back into layout.
final class PanelPresentation {
    weak var view: NSView?

    var size: CGSize? {
        guard let view, view.superview != nil else { return nil }
        let size = view.layer?.presentation()?.bounds.size ?? view.bounds.size
        return size.width > 0 && size.height > 0 ? size : nil
    }
}

struct PanelPresentationReader: NSViewRepresentable {
    let presentation: PanelPresentation

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        presentation.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension Animation {
    static let panelOpen = Animation.smooth(duration: 0.32, extraBounce: 0)
    static let panelClose = Animation.spring(PanelMotion.closeSpring)
}

extension AnyTransition {
    static func panelContent(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6))
                .animation(.easeOut(duration: 0.18).delay(0.06)),
            removal: .opacity.combined(with: .offset(y: -6))
                .animation(.easeOut(duration: 0.10))
        )
    }

    static func panelCompact(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.12).delay(0.20)),
            removal: .opacity.animation(.easeOut(duration: 0.08))
        )
    }
}

/// Every panel animation stays here. Modifier order is intentional: the
/// innermost matching modifier wins when several values change together.
struct PanelAnimationInputs: Equatable {
    var notchSize: CGSize
    var status: NotchStatus
    var expandingActivity: ExpandingActivity
    var hasPendingPermission: Bool
    var hasWaitingForInput: Bool
    var showMusicActivity: Bool
    var vibeGlowEnabled: Bool
    var notchAppearanceStyleRaw: String
    var artworkData: Data?
    var isBouncing: Bool
}

extension View {
    func panelAnimationContract(
        inputs: PanelAnimationInputs,
        reduceMotion: Bool
    ) -> some View {
        self
            // Open/close changes BOTH status and size. Keep status innermost
            // so its one curve owns the shell and corners. Content has a
            // shorter transition so text disappears before the clip reaches it.
            .animation(
                reduceMotion ? nil : (inputs.status == .opened ? .panelOpen : .panelClose),
                value: inputs.status
            )
            // A picker changes size only. Keep its existing 0.2s curve in
            // sync with ExpandableContent; never let the shell spring here.
            // See docs/debug/2026-06-30-appearance-style-scrollbar-regression.md.
            .animation(reduceMotion ? nil : .settingsExpand, value: inputs.notchSize)
            .animation(reduceMotion ? nil : .settingsExpand, value: inputs.expandingActivity)
            .animation(reduceMotion ? nil : .settingsExpand, value: inputs.hasPendingPermission)
            .animation(reduceMotion ? nil : .settingsExpand, value: inputs.hasWaitingForInput)
            .animation(reduceMotion ? nil : .settingsExpand, value: inputs.showMusicActivity)
            .animation(reduceMotion ? nil : .settingsExpand, value: inputs.vibeGlowEnabled)
            .animation(reduceMotion ? nil : .settingsExpand, value: inputs.notchAppearanceStyleRaw)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: inputs.artworkData)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: inputs.isBouncing)
    }
}
