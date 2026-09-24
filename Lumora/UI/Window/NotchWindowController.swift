//
//  NotchWindowController.swift
//  Lumora
//
//  Controls the notch window positioning and lifecycle
//

import AppKit
import Combine
import SwiftUI

class NotchWindowController: NSWindowController {
    let viewModel: NotchViewModel
    private let screen: NSScreen
    private var cancellables = Set<AnyCancellable>()

    init(screen: NSScreen, animateOnLaunch: Bool = true) {
        self.screen = screen

        let screenFrame = screen.frame
        let notchSize = screen.notchSize

        // Window covers full width at top, tall enough for largest content (chat view)
        let windowHeight: CGFloat = 750
        let windowFrame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - windowHeight,
            width: screenFrame.width,
            height: windowHeight
        )

        // Device notch rect - positioned at center
        let deviceNotchRect = CGRect(
            x: (screenFrame.width - notchSize.width) / 2,
            y: 0,
            width: notchSize.width,
            height: notchSize.height
        )

        // Create view model
        self.viewModel = NotchViewModel(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenFrame,
            windowHeight: windowHeight,
            hasPhysicalNotch: screen.hasPhysicalNotch
        )

        // Create the window
        let notchWindow = NotchPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: notchWindow)

        // Create the SwiftUI view with pass-through hosting
        let hostingController = NotchViewController(viewModel: viewModel)
        notchWindow.contentViewController = hostingController

        notchWindow.setFrame(windowFrame, display: true)

        // Preserve the visible hit area throughout an interruptible close.
        viewModel.$status.combineLatest(viewModel.$isClosing, MenuBarOrganizer.shared.$isExpanded,
                                        MenuBarOrganizer.shared.$isYieldingToSystem)
            .sink { [weak notchWindow] status, isClosing, isExpanded, isYielding in
                let isShowingMenuBar = isExpanded || isYielding
                notchWindow?.ignoresMouseEvents = isShowingMenuBar || (status != .opened && !isClosing)
                notchWindow?.alphaValue = isShowingMenuBar ? 0 : 1
                if isShowingMenuBar { notchWindow?.resignKey() }
            }
            .store(in: &cancellables)

        viewModel.$closedNotchExpansionWidth
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuBarProtection() }
            .store(in: &cancellables)
        updateMenuBarProtection()

        // Focus changes once per logical open/close, independently of rendering.
        viewModel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak notchWindow, weak viewModel] status in
                switch status {
                case .opened:
                    // Don't steal focus when opened by notification (task finished)
                    if viewModel?.openReason != .notification, !MenuBarOrganizer.shared.isExpanded,
                       !MenuBarOrganizer.shared.isYieldingToSystem {
                        NSApp.activate(ignoringOtherApps: false)
                        notchWindow?.makeKey()
                    }
                case .closed, .popping:
                    notchWindow?.resignKey()
                }
            }
            .store(in: &cancellables)

        // Start with ignoring mouse events (closed state)
        notchWindow.ignoresMouseEvents = true

        // Let ShortcutManager know the current content type so chat-specific
        // hardcoded scroll keys (↑/↓/⌃F/⌃B) dispatch correctly.
        ShortcutManager.shared.contentTypeProvider = { [weak viewModel] in
            guard let viewModel, viewModel.status == .opened else { return .instances }
            return viewModel.contentType
        }

        // Start local keyboard monitor (stays active regardless of notch state)
        ShortcutManager.shared.startLocalMonitor()

        // Register global hotkey (e.g. ⌥⌘L to open notch)
        ShortcutManager.shared.registerGlobalHotkey()

        // Listen for global hotkey toggle (Carbon) — route through handleShortcutAction
        // to ensure currentChatSession is cleared for instances page.
        NotificationCenter.default.addObserver(
            forName: .globalToggleNotch,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.viewModel.handleShortcutAction(.toggleNotch)
        }

        // Listen for local shortcut actions (routed from ShortcutManager)
        NotificationCenter.default.addObserver(
            forName: .shortcutAction,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let action = notification.object as? ShortcutAction else { return }
            self.viewModel.handleShortcutAction(action)
        }

        // Perform boot animation after a brief delay (only on initial launch)
        if animateOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.viewModel.performBootAnimation()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateMenuBarProtection() {
        // The resident compact strip competes with system icons. Opening Lumora
        // intentionally must not enlarge this probe and hide its own window.
        let width = viewModel.geometry.closedPanelSize(expansionWidth: viewModel.closedNotchExpansionWidth).width
        let height = max(24, screen.safeAreaInsets.top)
        MenuBarOrganizer.shared.protectMenuBarRect(CGRect(
            x: screen.frame.midX - width / 2, y: screen.frame.maxY - height,
            width: width, height: height
        ))
    }
}
