//
//  HookInstaller.swift
//  Lumora
//
//  Auto-installs Claude Code hooks on app launch
//

import Foundation

struct HookInstaller {

    /// Install hook script and update settings.json on app launch
    static func installIfNeeded() {
        let hooksDir = ClaudePaths.hooksDir
        let pythonScript = hooksDir.appendingPathComponent("lumora-state.py")

        do {
            guard let bundled = Bundle.main.url(forResource: "lumora-state", withExtension: "py") else { return }
            try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
            try Data(contentsOf: bundled).write(to: pythonScript, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pythonScript.path)
            let command = "\(detectPython()) \(ClaudePaths.hookScriptShellPath)"
            try updateSettings(at: ClaudePaths.settingsFile, command: command)
            // Existing agent processes cache commands even after settings change.
            try installLegacyForwarder(at: hooksDir.appendingPathComponent("nook-state.py"), forwardingTo: "lumora-state.py")
        } catch {
            NSLog("Lumora: Claude hook installation failed: %@", error.localizedDescription)
        }
    }

    /// A compatibility entry point for commands cached by already-running agents.
    /// execv preserves stdin, stdout, arguments and the replacement script's exit code.
    /// Only the new path is registered, so this never installs a second callback.
    nonisolated static func installLegacyForwarder(at url: URL, forwardingTo filename: String) throws {
        let script = """
        #!/usr/bin/env python3
        # Lumora compatibility entry point for an already-running agent session.
        import os
        import sys
        from pathlib import Path
        target = str(Path(__file__).with_name("\(filename)"))
        os.execv(sys.executable, [sys.executable, target, *sys.argv[1:]])
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    nonisolated static func updateSettings(at settingsURL: URL, command: String?) throws {
        let original = FileManager.default.fileExists(atPath: settingsURL.path)
            ? try Data(contentsOf: settingsURL) : nil
        try updatedConfiguration(original, command: command).write(to: settingsURL, options: .atomic)
    }

    /// Transform only our callbacks. Reject malformed data before any write.
    nonisolated static func updatedConfiguration(_ original: Data?, command: String?) throws -> Data {
        var json: [String: Any] = [:]
        if let original {
            guard let value = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            json = value
        }
        guard json["hooks"] == nil || json["hooks"] is [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]],
                  entries.allSatisfy({ $0["hooks"] == nil || $0["hooks"] is [[String: Any]] }) else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            let cleaned = entries.compactMap { removingLumoraHooks(from: $0) }
            if cleaned.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = cleaned }
        }
        if let command {
            let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
            let hookEntryWithTimeout: [[String: Any]] = [["type": "command", "command": command, "timeout": 86400]]
            let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
            let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
            let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
            let preCompactConfig: [[String: Any]] = [
                ["matcher": "auto", "hooks": hookEntry],
                ["matcher": "manual", "hooks": hookEntry]
            ]

            let hookEvents: [(String, [[String: Any]])] = [
                ("UserPromptSubmit", withoutMatcher),
                ("PreToolUse", withMatcher),
                ("PostToolUse", withMatcher),
                // PostToolUseFailure fires when a tool errored or was interrupted — we
                // currently miss these signals entirely (v2.0.x+)
                ("PostToolUseFailure", withMatcher),
                ("PermissionRequest", withMatcherAndTimeout),
                // PermissionDenied surfaces auto-mode classifier denials (v2.1.88+)
                ("PermissionDenied", withMatcher),
                ("Notification", withMatcher),
                ("Stop", withoutMatcher),
                // StopFailure fires on API errors (rate limit, auth, billing) — lets
                // us show the failure in the notch instead of appearing stuck (v2.1.78+)
                ("StopFailure", withoutMatcher),
                // SubagentStart pairs with existing SubagentStop (v2.0.43+)
                ("SubagentStart", withoutMatcher),
                ("SubagentStop", withoutMatcher),
                ("SessionStart", withoutMatcher),
                ("SessionEnd", withoutMatcher),
                ("PreCompact", preCompactConfig),
                // PostCompact pairs with PreCompact so the UI can exit the
                // .compacting phase cleanly (v2.1.76+)
                ("PostCompact", preCompactConfig),
            ]

            for (event, config) in hookEvents {
                let existingEvent = hooks[event] as? [[String: Any]] ?? []
                let cleanedEvent = existingEvent.compactMap { removingLumoraHooks(from: $0) }
                hooks[event] = cleanedEvent + config
            }

        }
        if hooks.isEmpty { json.removeValue(forKey: "hooks") }
        else { json["hooks"] = hooks }
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    /// Check if hooks are currently installed
    static func isInstalled() -> Bool {
        let settings = ClaudePaths.settingsFile

        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in entryHooks {
                            if let cmd = hook["command"] as? String,
                               cmd.contains("lumora-state.py") {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
    }

    /// Uninstall hooks from settings.json and remove script
    static func uninstall() {
        do {
            try updateSettings(at: ClaudePaths.settingsFile, command: nil)
            for name in ["lumora-state.py", "nook-state.py"] {
                try? FileManager.default.removeItem(at: ClaudePaths.hooksDir.appendingPathComponent(name))
            }
        } catch {
            NSLog("Lumora: Claude hook removal failed: %@", error.localizedDescription)
        }
    }

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}

        return "python"
    }

    nonisolated private static func removingLumoraHooks(from entry: [String: Any]) -> [String: Any]? {
        guard var entryHooks = entry["hooks"] as? [[String: Any]] else {
            return entry
        }

        entryHooks.removeAll(where: isLumoraHook)
        guard !entryHooks.isEmpty else { return nil }

        var updatedEntry = entry
        updatedEntry["hooks"] = entryHooks
        return updatedEntry
    }

    nonisolated private static func isLumoraHook(_ hook: [String: Any]) -> Bool {
        let cmd = hook["command"] as? String ?? ""
        return cmd.contains("lumora-state.py") || cmd.contains("nook-state.py")
    }
}
