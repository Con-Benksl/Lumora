//
//  LumoraApp.swift
//  Lumora
//
//  Dynamic Island for monitoring Claude Code instances
//

import SwiftUI

@main
struct LumoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // We use a completely custom window, so no default scene needed
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.windowController?.viewModel.handleShortcutAction(.openSettings)
                }
                .keyboardShortcut(",")
                Button("Menu Bar Settings…") {
                    MenuBarOrganizer.shared.showSettings()
                }
            }
        }
    }
}
