import SwiftUI

struct MenuBarSettingsView: View {
    @ObservedObject private var organizer = MenuBarOrganizer.shared

    var body: some View {
        Form {
            if organizer.usesSystemMenuBar {
                Section("System Menu Bar") {
                    Toggle(isOn: Binding(
                        get: { organizer.isEnabled },
                        set: { organizer.setEnabled($0) }
                    )) {
                        Text("Automatically Avoid Menu Bar Icons")
                    }

                    Text("Lumora steps aside when system menu bar icons overlap its panel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Open Menu Bar Settings…") {
                        organizer.openSystemMenuBarSettings()
                    }

                    if organizer.needsAccessibility {
                        Text("Allow Accessibility so Lumora can determine where menu bar icons are.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open Accessibility Settings…") {
                            organizer.openAccessibilitySettings()
                        }
                    }

                    if organizer.isYieldingToSystem {
                        Label("Lumora is making room for menu bar icons.", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("System Menu Bar") {
                    Text("Automatic menu bar avoidance requires macOS 27 or later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Menu Bar Settings…") {
                        organizer.openSystemMenuBarSettings()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 360)
    }
}
