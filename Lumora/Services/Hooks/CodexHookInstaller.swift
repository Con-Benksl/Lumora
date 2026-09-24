//
//  CodexHookInstaller.swift
//  Lumora
//
//  Installs Codex hooks that forward session lifecycle events
//  into Lumora via the shared Unix socket.
//

import Foundation

struct CodexHookInstaller {
    private static let codexDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    private static let hooksDir = codexDir.appendingPathComponent("hooks")
    private static let configFile = codexDir.appendingPathComponent("config.toml")
    private static let hooksFile = codexDir.appendingPathComponent("hooks.json")
    private static let bridgeScript = hooksDir.appendingPathComponent("lumora-codex-hook.py")

    static func installIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
            try installBridgeScript()
            let command = "\(detectPythonExecutable()) \(shellQuote(bridgeScript.path))"
            try updateHooks(at: hooksFile, command: command)
            // Commands may remain cached in a running session after settings migrate.
            try HookInstaller.installLegacyForwarder(at: hooksDir.appendingPathComponent("nook-codex-hook.py"), forwardingTo: "lumora-codex-hook.py")
            enableHooksFeature()
        } catch {
            NSLog("Lumora: Codex hook installation failed: %@", error.localizedDescription)
        }
    }

    private static func installBridgeScript() throws {
        let script = """
        #!/usr/bin/env python3
        import json
        import os
        import socket
        import sys

        SOCKET_PATH = "/tmp/lumora.sock"

        def main():
            payload = sys.stdin.buffer.read()
            if not payload.strip():
                return

            try:
                event = json.loads(payload.decode("utf-8"))
                event.setdefault("origin", "codex")
                event.setdefault("cwd", os.getcwd())
                payload = (json.dumps(event, separators=(",", ":")) + "\\n").encode("utf-8")
            except Exception:
                pass

            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.settimeout(2)
                sock.connect(SOCKET_PATH)
                sock.sendall(payload)
                sock.close()
            except OSError:
                pass

        if __name__ == "__main__":
            main()
        """

        try script.write(to: bridgeScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bridgeScript.path
        )
    }

    private static func enableHooksFeature() {
        let existing: String
        if FileManager.default.fileExists(atPath: configFile.path) {
            guard let contents = try? String(contentsOf: configFile, encoding: .utf8) else { return }
            existing = contents
        } else {
            existing = ""
        }

        if rangeOfCanonicalHooksFlag(true, in: existing) != nil {
            return
        }

        let updated: String
        if let disabledFlagRange = rangeOfCanonicalHooksFlag(false, in: existing) {
            let disabledFlag = String(existing[disabledFlagRange])
            let enabledFlag = disabledFlag.replacingOccurrences(
                of: #"(?m)^(\s*)hooks\s*=\s*false(\s*(?:#.*)?)$"#,
                with: "$1hooks = true$2",
                options: .regularExpression
            )
            updated = existing.replacingCharacters(in: disabledFlagRange, with: enabledFlag)
        } else if let featureRange = existing.range(
            of: #"(?m)^\s*\[features\]\s*$"#,
            options: .regularExpression
        ) {
            let tail = existing[featureRange.upperBound...]
            if let nextSectionRange = tail.range(
                of: #"(?m)^\s*\[[^\n]+\]\s*$"#,
                options: .regularExpression
            ) {
                let insertionPoint = nextSectionRange.lowerBound
                let prefix = String(existing[..<insertionPoint])
                let separator = prefix.hasSuffix("\n") ? "" : "\n"
                updated = prefix + separator + "hooks = true\n" + String(existing[insertionPoint...])
            } else if existing.hasSuffix("\n") {
                updated = existing + "hooks = true\n"
            } else {
                updated = existing + "\nhooks = true\n"
            }
        } else if existing.isEmpty {
            updated = "[features]\nhooks = true\n"
        } else {
            let suffix = existing.hasSuffix("\n") ? "" : "\n"
            updated = existing + suffix + "\n[features]\nhooks = true\n"
        }

        // Do not let a conservative text edit damage an unfamiliar or malformed
        // TOML layout. If Python lacks tomllib, preserve the file unchanged.
        guard isValidTOML(updated) else { return }
        try? updated.write(to: configFile, atomically: true, encoding: .utf8)
    }

    private static func isValidTOML(_ text: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // Read stdin before importing tomllib so older Python versions still drain
        // the pipe before exiting. No configuration contents are logged.
        process.arguments = ["python3", "-c", "import sys; data = sys.stdin.read(); import tomllib; tomllib.loads(data)"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            try? input.fileHandleForWriting.close()
            return false
        }
    }

    private static func rangeOfCanonicalHooksFlag(_ value: Bool, in text: String) -> Range<String.Index>? {
        guard let featuresSectionRange = featuresSectionBodyRange(in: text) else { return nil }
        let boolValue = value ? "true" : "false"
        let pattern = #"(?m)^\s*hooks\s*=\s*"# + boolValue + #"\s*(?:#.*)?$"#
        return text[featuresSectionRange].range(of: pattern, options: .regularExpression)
    }

    private static func featuresSectionBodyRange(in text: String) -> Range<String.Index>? {
        guard let featureRange = text.range(
            of: #"(?m)^\s*\[features\]\s*$"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let bodyStart = featureRange.upperBound
        let tail = text[bodyStart...]
        let bodyEnd = tail.range(
            of: #"(?m)^\s*\[[^\n]+\]\s*$"#,
            options: .regularExpression
        )?.lowerBound ?? text.endIndex
        return bodyStart..<bodyEnd
    }

    nonisolated static func updateHooks(at url: URL, command: String?) throws {
        let original = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        try updatedConfiguration(original, command: command).write(to: url, options: .atomic)
    }

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
            let handler: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": 5,
            ]
            let sessionEndHandler: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": 3,
            ]
            let allEvents: [(String, [[String: Any]])] = [
                ("SessionStart", [["matcher": "startup|resume|clear|compact", "hooks": [handler]]]),
                ("SessionEnd", [["hooks": [sessionEndHandler]]]),
                ("UserPromptSubmit", [["hooks": [handler]]]),
                ("PreToolUse", [["hooks": [handler]]]),
                ("PermissionRequest", [["hooks": [handler]]]),
                ("PostToolUse", [["hooks": [handler]]]),
                ("PreCompact", [["hooks": [handler]]]),
                ("PostCompact", [["hooks": [handler]]]),
                ("SubagentStart", [["hooks": [handler]]]),
                ("SubagentStop", [["hooks": [handler]]]),
                ("Stop", [["hooks": [handler]]]),
            ]

            for (event, config) in allEvents {
                let existingEntries = hooks[event] as? [[String: Any]] ?? []
                let cleanedEntries = existingEntries.compactMap { removingLumoraHooks(from: $0) }
                hooks[event] = cleanedEntries + config
            }

        }
        if hooks.isEmpty { json.removeValue(forKey: "hooks") }
        else { json["hooks"] = hooks }
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    /// Check if Codex hooks are currently installed
    static func isInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: bridgeScript.path) else { return false }

        guard let data = try? Data(contentsOf: hooksFile),
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
                               cmd.contains("lumora-codex-hook.py") {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
    }

    /// Uninstall only Lumora's Codex hooks. Preserve the shared hooks feature flag
    /// because the user may have other personal or plugin-provided hooks.
    static func uninstall() {
        do {
            try updateHooks(at: hooksFile, command: nil)
            for name in ["lumora-codex-hook.py", "nook-codex-hook.py"] {
                try? FileManager.default.removeItem(at: hooksDir.appendingPathComponent(name))
            }
        } catch {
            NSLog("Lumora: Codex hook removal failed: %@", error.localizedDescription)
        }
    }

    private nonisolated static func removingLumoraHooks(from entry: [String: Any]) -> [String: Any]? {
        guard var entryHooks = entry["hooks"] as? [[String: Any]] else {
            return entry
        }

        entryHooks.removeAll(where: isLumoraHook)
        guard !entryHooks.isEmpty else { return nil }

        var updatedEntry = entry
        updatedEntry["hooks"] = entryHooks
        return updatedEntry
    }

    private nonisolated static func isLumoraHook(_ hook: [String: Any]) -> Bool {
        let command = hook["command"] as? String ?? ""
        return command.contains("lumora-codex-hook.py") || command.contains("nook-codex-hook.py")
    }

    private static func detectPythonExecutable() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0,
               let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {}

        return "python3"
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
