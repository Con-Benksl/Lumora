import AppKit
import SwiftUI

/// Attach inside the scroll content so the probe finds only its own scroll view.
/// A nonzero overlay keeps SwiftUI from eliding the representable during layout.
struct ScrollViewOverlayStyle: NSViewRepresentable {
    let isActive: Bool
    let onMeasure: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollViewOverlayObserver {
        ScrollViewOverlayObserver()
    }

    func updateNSView(_ nsView: ScrollViewOverlayObserver, context: Context) {
        nsView.onMeasure = onMeasure
        nsView.isActive = isActive
    }

    static func dismantleNSView(_ nsView: ScrollViewOverlayObserver, coordinator: ()) {
        nsView.isActive = false
        nsView.onMeasure = nil
    }
}

final class ScrollViewOverlayObserver: NSView {
    var onMeasure: ((CGFloat) -> Void)?
    var isActive = false {
        didSet { updateObservation() }
    }

    private weak var scrollView: NSScrollView?
    private var timer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateObservation()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateObservation()
    }

    deinit {
        timer?.invalidate()
    }

    private func updateObservation() {
        guard isActive, window != nil, let target = enclosingScrollView else {
            timer?.invalidate()
            timer = nil
            scrollView = nil
            return
        }
        guard scrollView !== target || timer == nil else { return }
        timer?.invalidate()
        scrollView = target
        applyOverlayStyle(to: target)

        // Keep the existing 10Hz settling samples, but only for the visible menu.
        // Never walk NSApp.windows or publish from inside SwiftUI's layout pass.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.measure()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func measure() {
        guard isActive, let window, let scrollView,
              scrollView.window === window else {
            updateObservation()
            return
        }
        if scrollView.scrollerStyle != .overlay {
            applyOverlayStyle(to: scrollView)
        }
        guard let height = scrollView.documentView?.frame.height,
              height.isFinite, height > 0 else { return }
        onMeasure?(height)
    }

    private func applyOverlayStyle(to scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
    }
}
