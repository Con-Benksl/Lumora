import AppKit
import SwiftUI
import os.log

class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?

    static var shared: AppDelegate?

    var windowController: NotchWindowController? {
        windowManager?.windowController
    }

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !ensureSingleInstance() || !ensurePreviousVersionIsNotRunning() {
            NSApplication.shared.terminate(nil)
            return
        }

        // (scroller style override removed 2026-07-02: all three
        // attempts to set overlay globally crashed at launch:
        //   1) +[NSScroller setPreferredScrollerStyle:] — selector
        //      does not exist in AppKit
        //   2) NSScrollView.appearance().scrollerStyle — Swift
        //      resolves `appearance` to NSAppearanceCustomization
        //      instance property, not the +appearance class method
        //   3) NSClassFromString("NSScrollView") +
        //      perform("appearance") — also unrecognized (no
        //      class-level +appearance method exists in AppKit
        //      public API)
        // See docs/specs/2026-07-01-picker-panel-height-redesign.md
        // "决策 0" for the full investigation log. The picker-panel-height
        // redesign made the buffer obsolete — panel maxHeight equals
        // ScrollView contentSize at every frame (compile-time row heights),
        // so no slack is needed.)

        AppSettings.registerDefaults()

        // Start the on-disk debug log mirror as early as possible so
        // that startup-time diagnostics (hook installer, socket bind)
        // are captured. The file is recreated on every launch.
        if AppSettings.debugLogEnabled {
            DebugLog.shared.enable()
            DebugLog.shared.log(
                Logger(subsystem: "com.conbenksl.lumora", category: "App"),
                level: .default,
                "app launched, debug log enabled → \(DebugLog.fileURL.path)"
            )
        }

        if AppSettings.autoInstallHooks {
            if AppSettings.claudeHooksEnabled { HookInstaller.installIfNeeded() }
            if AppSettings.codexHooksEnabled { CodexHookInstaller.installIfNeeded() }
            if AppSettings.opencodeHooksEnabled { OpencodeHookInstaller.installIfNeeded() }
            if AppSettings.cursorHooksEnabled { CursorHookInstaller.installIfNeeded() }
        }
        NSApplication.shared.setActivationPolicy(.accessory)

        windowManager = WindowManager()
        _ = windowManager?.setupNotchWindow()
        MenuBarOrganizer.shared.start()

        screenObserver = ScreenObserver { [weak self] in
            self?.handleScreenChange()
        }

    }

    @MainActor
    private func handleScreenChange() {
        _ = windowManager?.setupNotchWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // An instance rejected at launch never owns the shared services.
        guard windowManager != nil else { return }
        MenuBarOrganizer.shared.stop()
        MusicAudioAnalyzer.shared.stop()
        screenObserver = nil
    }

    private func ensurePreviousVersionIsNotRunning() -> Bool {
        let previousBundleIDs = ["com.conbenksl.lingyu", "com.oaimgo.nook"]
        guard NSWorkspace.shared.runningApplications.contains(where: {
            guard let bundleID = $0.bundleIdentifier else { return false }
            return previousBundleIDs.contains(bundleID)
        }) else { return true }

        // Both versions manage Agent hooks. Wait for the previous application
        // to quit before migrating or reinstalling those integrations.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Quit the previous version before opening Lumora")
        alert.informativeText = String(localized: "A previous version is still running. Quit it, then reopen Lumora to move your AI Agent connections to this app.")
        alert.addButton(withTitle: String(localized: "Close Lumora"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        return false
    }

    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.conbenksl.lumora"
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }

        if runningApps.count > 1 {
            if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
                existingApp.activate()
            }
            return false
        }

        return true
    }
}
