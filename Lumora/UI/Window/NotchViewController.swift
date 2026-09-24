//
//  NotchViewController.swift
//  Lumora
//
//  Hosts the SwiftUI NotchView in AppKit with click-through support
//

import AppKit
import SwiftUI

/// Custom NSHostingView that only accepts mouse events within the panel bounds.
/// Clicks outside the panel pass through to windows behind.
class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var hitTestRect: () -> CGRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only accept hits within the panel rect
        let localPoint = convert(point, from: superview)
        guard hitTestRect().contains(localPoint) else {
            return nil  // Pass through to windows behind
        }
        return super.hitTest(point)
    }
}

class NotchViewController: NSViewController {
    private let viewModel: NotchViewModel
    private var hostingView: PassThroughHostingView<NotchView>!

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        hostingView = PassThroughHostingView(rootView: NotchView(viewModel: viewModel))

        // Keep bounds in hosting-view coordinates, matching the point conversion
        // in hitTest. AppKit handles flipped views and displays with any origin.
        hostingView.hitTestRect = { [weak self] in
            guard let self, let window = self.hostingView.window else { return .zero }
            let vm = self.viewModel
            let geometry = vm.geometry
            let screenRect = geometry.openedScreenRect(for: vm.interactionSize)
            return self.hostingView.convert(window.convertFromScreen(screenRect), from: nil)
        }

        self.view = hostingView
    }
}
