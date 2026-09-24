//
//  CursorHookInstaller.swift
//  Lumora
//
//  Installs Cursor user hooks that forward agent lifecycle events
//  into Lumora via the shared Unix socket.
//

import Foundation

struct CursorHookInstaller {
    private static var cursorDir: URL {
        AgentPathsResolver.directory(for: .cursor)
    }

    private static var hooksDir: URL {
        AgentPathsResolver.hooksDirectory(for: .cursor)
    }

    private static var hooksFile: URL {
        cursorDir.appendingPathComponent("hooks.json")
    }

    private static var bridgeScript: URL {
        hooksDir.appendingPathComponent("lumora-cursor-hook.py")
    }

    static func installIfNeeded() {
        guard AgentPathsResolver.isInstalled(.cursor) else { return }
        do {
            try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
            try installBridgeScript()
            let command = "\(detectPythonExecutable()) \(shellQuote(bridgeScript.path))"
            try updateHooks(at: hooksFile, command: command)
            try HookInstaller.installLegacyForwarder(at: hooksDir.appendingPathComponent("nook-cursor-hook.py"), forwardingTo: "lumora-cursor-hook.py")
        } catch {
            NSLog("Lumora: Cursor hook installation failed: %@", error.localizedDescription)
        }
    }

    static func uninstall() {
        do {
            try updateHooks(at: hooksFile, command: nil)
            for name in ["lumora-cursor-hook.py", "nook-cursor-hook.py"] {
                try? FileManager.default.removeItem(at: hooksDir.appendingPathComponent(name))
            }
        } catch {
            NSLog("Lumora: Cursor hook removal failed: %@", error.localizedDescription)
        }
    }

    static func isInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: bridgeScript.path),
              let data = try? Data(contentsOf: hooksFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for (_, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            if entries.contains(where: { ($0["command"] as? String)?.contains("lumora-cursor-hook.py") == true }) {
                return true
            }
        }

        return false
    }

    private static func installBridgeScript() throws {
        let script = """
        #!/usr/bin/env python3
        import json
        import os
        import socket
        import sys

        SOCKET_PATH = "/tmp/lumora.sock"

        def hook_response(event_name):
            normalized = (event_name or "").replace("_", "").replace("-", "").lower()
            if normalized in {
                "pretooluse",
                "beforeshellexecution",
                "beforemcpexecution",
                "beforereadfile",
                "beforetabfileread",
                "subagentstart",
            }:
                return {"permission": "allow"}
            if normalized == "beforesubmitprompt":
                return {"continue": True}
            return {}

        def forward(payload):
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.settimeout(2)
                sock.connect(SOCKET_PATH)
                sock.sendall(payload)
                sock.close()
            except OSError:
                pass

        def main():
            raw = sys.stdin.buffer.read()
            event_name = ""
            payload = raw

            if raw.strip():
                try:
                    event = json.loads(raw.decode("utf-8"))
                    event_name = event.get("hook_event_name") or event.get("event") or ""
                    event["origin"] = "cursor"
                    payload = (json.dumps(event, separators=(",", ":")) + "\\n").encode("utf-8")
                except Exception:
                    pass

                forward(payload)

            sys.stdout.write(json.dumps(hook_response(event_name), separators=(",", ":")))
            sys.stdout.flush()

        if __name__ == "__main__":
            main()
        """

        try script.write(to: bridgeScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bridgeScript.path
        )
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
            guard let entries = value as? [[String: Any]] else { throw CocoaError(.propertyListReadCorrupt) }
            let cleaned = entries.filter { !isLumoraHook($0) }
            if cleaned.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = cleaned }
        }
        if let command {
            json["version"] = json["version"] ?? 1
            let handler: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": 5
            ]

            let events = [
                "sessionStart",
                "beforeSubmitPrompt",
                "preToolUse",
                "postToolUse",
                "postToolUseFailure",
                "afterAgentResponse",
                "afterAgentThought",
                "preCompact",
                "subagentStart",
                "subagentStop",
                "stop",
                "sessionEnd",
            ]

            for event in events {
                let existingEntries = hooks[event] as? [[String: Any]] ?? []
                hooks[event] = existingEntries.filter { !isLumoraHook($0) } + [handler]
            }

        }
        if hooks.isEmpty { json.removeValue(forKey: "hooks") }
        else { json["hooks"] = hooks }
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    private nonisolated static func isLumoraHook(_ hook: [String: Any]) -> Bool {
        let command = hook["command"] as? String ?? ""
        return command.contains("lumora-cursor-hook.py") || command.contains("nook-cursor-hook.py")
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
