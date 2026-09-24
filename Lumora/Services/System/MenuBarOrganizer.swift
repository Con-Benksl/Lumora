import AppKit
import Combine
import SwiftUI

/// Coordinates the system-owned menu bar and keeps Lumora's panel out of its way.
@MainActor
final class MenuBarOrganizer: ObservableObject {
    static let shared = MenuBarOrganizer()
    private static let enabledKey = "menuBarOrganizerEnabled"

    @Published private(set) var isEnabled = false
    @Published private(set) var isExpanded = false
    @Published private(set) var isYieldingToSystem = false
    @Published private(set) var needsAccessibility = false

    var usesSystemMenuBar: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    private let systemMonitor = SystemMenuBarMonitor()
    private var avoidanceState = MenuBarAvoidanceState()
    private var systemItemFrames: [CGRect]?
    private var protectedMenuBarRect: CGRect?
    private var settingsWindow: NSWindow?
    private var hasStarted = false

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        guard usesSystemMenuBar, UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        isEnabled = true
        startSystemMonitor()
    }

    func setEnabled(_ enabled: Bool) {
        guard usesSystemMenuBar, enabled != isEnabled else { return }
        isEnabled = enabled
        isExpanded = false
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            startSystemMonitor()
        } else {
            stopSystemMonitor()
        }
    }

    /// Menu-bar visibility is managed by macOS; Lumora does not fold other apps' items.
    func toggleExpanded() {}
    func hide() {}

    func beginArrangement() {
        openSystemMenuBarSettings()
    }

    func protectMenuBarRect(_ rect: CGRect) {
        guard protectedMenuBarRect != rect else { return }
        protectedMenuBarRect = rect
        updateSystemAvoidance()
    }

    private func startSystemMonitor() {
        avoidanceState.begin()
        isYieldingToSystem = avoidanceState.isYielding
        systemMonitor.start { [weak self] frames, trusted in
            guard let self, self.isEnabled, self.usesSystemMenuBar else { return }
            self.systemItemFrames = frames
            self.needsAccessibility = !trusted
            self.updateSystemAvoidance()
        }
    }

    private func stopSystemMonitor() {
        systemMonitor.stop()
        systemItemFrames = nil
        needsAccessibility = false
        avoidanceState.stop()
        isYieldingToSystem = avoidanceState.isYielding
    }

    private func updateSystemAvoidance() {
        guard usesSystemMenuBar, isEnabled else { return }
        isYieldingToSystem = avoidanceState.update(
            items: systemItemFrames,
            protectedRect: protectedMenuBarRect
        )
    }

    func openSystemMenuBarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func showSettings() {
        AppDelegate.shared?.windowController?.viewModel.notchClose()
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = String(localized: "Menu Bar Avoidance")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MenuBarSettingsView())
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func stop() {
        stopSystemMonitor()
        isEnabled = false
        isExpanded = false
        hasStarted = false
        settingsWindow?.close()
    }
}
