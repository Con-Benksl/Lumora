#!/usr/bin/env python3
"""Exercise the real Swift hook transforms using only disposable configuration files."""
from pathlib import Path
import json
import os
import socket
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[1]
harness = r'''
import Foundation

enum AgentKind { case cursor, opencode }
enum AgentPathsResolver {
    static func directory(for _: AgentKind) -> URL { URL(fileURLWithPath: "/unused-lumora-test") }
    static func hooksDirectory(for _: AgentKind) -> URL { directory(for: .cursor) }
    static func isInstalled(_: AgentKind) -> Bool { false }
}
enum ClaudePaths {
    static let hooksDir = URL(fileURLWithPath: "/unused-lumora-test")
    static let settingsFile = hooksDir.appendingPathComponent("settings.json")
    static let hookScriptShellPath = "'/unused-lumora-test/lumora-state.py'"
}

@main struct HookMigrationCheck {
    static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }
    static func decode(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func checkNested(
        _ name: String,
        transform: (Data?, String?) throws -> Data,
        write: (URL, String?) throws -> Void,
        directory: URL
    ) throws {
        let other: [String: Any] = ["type": "command", "command": "echo personal", "timeout": 9]
        let old: [String: Any] = ["type": "command", "command": "python3 '/tmp/nook-\(name).py'"]
        let new = "python3 '/tmp/lumora-\(name).py'"
        let input = try encode([
            "custom": ["preserve": true],
            "hooks": [
                "Stop": [["matcher": "custom", "hooks": [old, other]]],
                "LegacyEvent": [["hooks": [old]]],
                "UnrelatedEvent": [["hooks": [other]]],
            ],
        ])
        let result = try transform(input, new)
        let json = try decode(result)
        assert((json["custom"] as? [String: Bool])?["preserve"] == true)
        let hooks = json["hooks"] as! [String: [[String: Any]]]
        assert(hooks["LegacyEvent"] == nil, "Removed events must not keep stale callbacks")
        let preserved = hooks["Stop"]!.first!
        assert(preserved["matcher"] as? String == "custom")
        assert(NSDictionary(dictionary: (preserved["hooks"] as! [[String: Any]])[0]).isEqual(to: other))
        assert(hooks["UnrelatedEvent"]?.count == 1)
        assert(!String(decoding: result, as: UTF8.self).contains("nook-\(name).py"))
        assert(try transform(result, new) == result, "Repeated launches must not duplicate callbacks")
        let removed = try decode(transform(result, nil))
        let remaining = removed["hooks"] as! [String: [[String: Any]]]
        assert(remaining.count == 2 && remaining["Stop"]?.count == 1)

        // Reject syntax errors, wrong roots, and malformed hook entries without writing.
        for malformed in ["{bad", "[]", "{\"hooks\":7}", "{\"hooks\":{\"Stop\":7}}",
                          "{\"hooks\":{\"Stop\":[{\"hooks\":7}]}}"] {
            let file = directory.appendingPathComponent(name + ".json")
            let bytes = Data(malformed.utf8)
            try bytes.write(to: file)
            do { try write(file, new); fatalError("Malformed settings accepted") } catch {}
            assert(try Data(contentsOf: file) == bytes)
        }
    }
    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--compatibility-fixtures" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            for suffix in ["state", "codex-hook", "cursor-hook"] {
                try HookInstaller.installLegacyForwarder(
                    at: directory.appendingPathComponent("nook-\(suffix).py"),
                    forwardingTo: "lumora-\(suffix).py"
                )
            }
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumora-hook-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try checkNested("state", transform: HookInstaller.updatedConfiguration,
                        write: HookInstaller.updateSettings, directory: directory)
        try checkNested("codex-hook", transform: CodexHookInstaller.updatedConfiguration,
                        write: CodexHookInstaller.updateHooks, directory: directory)

        let other: [String: Any] = ["command": "echo personal", "timeout": 12]
        let cursorInput = try encode(["version": 2, "custom": "keep", "hooks": [
            "stop": [["command": "python3 /tmp/nook-cursor-hook.py"], other],
            "oldEvent": [["command": "python3 /tmp/nook-cursor-hook.py"]],
            "otherEvent": [other],
        ]])
        let cursorCommand = "python3 /tmp/lumora-cursor-hook.py"
        let cursorResult = try CursorHookInstaller.updatedConfiguration(cursorInput, command: cursorCommand)
        let cursorJSON = try decode(cursorResult)
        assert(cursorJSON["version"] as? Int == 2 && cursorJSON["custom"] as? String == "keep")
        let cursorHooks = cursorJSON["hooks"] as! [String: [[String: Any]]]
        assert(cursorHooks["oldEvent"] == nil && cursorHooks["stop"]?.count == 2)
        assert(NSDictionary(dictionary: cursorHooks["stop"]![0]).isEqual(to: other))
        assert(try CursorHookInstaller.updatedConfiguration(cursorResult, command: cursorCommand) == cursorResult)
        assert(!String(decoding: cursorResult, as: UTF8.self).contains("nook-cursor"))
        let cursorRemoved = try decode(CursorHookInstaller.updatedConfiguration(cursorResult, command: nil))
        assert((cursorRemoved["hooks"] as! [String: [[String: Any]]]).count == 2)
        for invalid in ["{broken", "{\"hooks\":false}", "{\"hooks\":{\"stop\":false}}"] {
            let file = directory.appendingPathComponent("cursor.json")
            let bytes = Data(invalid.utf8)
            try bytes.write(to: file)
            do { try CursorHookInstaller.updateHooks(at: file, command: cursorCommand); fatalError("Invalid Cursor JSON accepted") } catch {}
            assert(try Data(contentsOf: file) == bytes)
        }

        let pluginDir = URL(fileURLWithPath: "/tmp/opencode fixture/plugins/lumora")
        let config = #"""
        {
          // Valid JSONC: comments, trailing comma, an unrelated URL and escaped characters.
          "custom": {"url": "https://example.test/a]b", "enabled": true},
          "plugin": ["./plugins/nook", "file:///tmp/opencode%20fixture/plugins/nook",
                     "other-plugin", "/tmp/opencode fixture/plugins/lumora",],
        }
        """#
        let openResult = try OpencodeHookInstaller.updatedConfiguration(Data(config.utf8), pluginDirectory: pluginDir, installing: true)
        let openJSON = try decode(openResult)
        assert(openJSON["plugin"] as? [String] == ["other-plugin", pluginDir.path])
        assert((openJSON["custom"] as? [String: Any])?["url"] as? String == "https://example.test/a]b")
        assert(try OpencodeHookInstaller.updatedConfiguration(openResult, pluginDirectory: pluginDir, installing: true) == openResult)
        let openRemoved = try decode(OpencodeHookInstaller.updatedConfiguration(openResult, pluginDirectory: pluginDir, installing: false))
        assert(openRemoved["plugin"] as? [String] == ["other-plugin"])
        for invalid in ["{broken", "[]", "{\"plugin\":false}", "{\"plugin\":[3]}"] {
            do {
                _ = try OpencodeHookInstaller.updatedConfiguration(Data(invalid.utf8), pluginDirectory: pluginDir, installing: true)
                fatalError("Invalid OpenCode settings accepted")
            } catch {}
        }
        print("PASS: all four real Swift installers migrate without duplicate callbacks, preserve unrelated config, and reject malformed input")
    }
}
'''
# Swift assert uses a non-throwing autoclosure: evaluate throwing expressions first.
harness = harness.replace('assert(try ', 'try expect(')
harness = harness.replace('@main struct HookMigrationCheck {', '''func expect(_ value: @autoclosure () throws -> Bool, _ message: String = "Assertion failed") throws {
    if try !value() { fatalError(message) }
}

@main struct HookMigrationCheck {''')
with tempfile.TemporaryDirectory(prefix="lumora-hook-swift-") as temp:
    temp = Path(temp)
    main = temp / "HookMigrationCheck.swift"
    main.write_text(harness)
    binary = temp / "hook-migration-check"
    files = [repo / "Lumora/Services/Hooks" / name for name in (
        "HookInstaller.swift", "CodexHookInstaller.swift", "CursorHookInstaller.swift", "OpencodeHookInstaller.swift"
    )]
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
                    "-parse-as-library", *map(str, files), str(main), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

    # Execute the actual Swift-generated compatibility scripts against a disposable
    # sender/socket, verifying transport plus stdin/argv/stdout/exit-code preservation.
    with tempfile.TemporaryDirectory(prefix="ly-compat-", dir="/tmp") as fixture:
        fixture = Path(fixture)
        subprocess.run([str(binary), "--compatibility-fixtures", str(fixture)], check=True)
        sender = """import json, os, socket, sys
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.connect(os.environ["LUMORA_TEST_SOCKET"])
client.sendall(json.dumps({"stdin": sys.stdin.read(), "argv": sys.argv[1:]}).encode())
client.close()
print("sender-ok")
sys.exit(23)
"""
        sock_path = str(fixture / "sender.sock")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(sock_path)
        listener.listen(3)
        listener.settimeout(3)
        try:
            for suffix in ("state", "codex-hook", "cursor-hook"):
                (fixture / f"lumora-{suffix}.py").write_text(sender)
                result = subprocess.run(
                    [sys.executable, str(fixture / f"nook-{suffix}.py"), "cached-session", "argument with spaces"],
                    input='{"hook_event_name":"PreToolUse","tool_name":"read"}\n',
                    text=True, capture_output=True, timeout=5,
                    env={**os.environ, "LUMORA_TEST_SOCKET": sock_path},
                )
                connection, _ = listener.accept()
                with connection:
                    payload = json.loads(connection.recv(8192))
                assert payload == {
                    "stdin": '{"hook_event_name":"PreToolUse","tool_name":"read"}\n',
                    "argv": ["cached-session", "argument with spaces"],
                }
                assert result.returncode == 23 and result.stdout == "sender-ok\n" and not result.stderr

            # Also drive the real bundled Claude hook through its cached old name.
            # Only the test copy's socket location is changed; no live socket is used.
            actual_sender = (repo / "Lumora/Resources/lumora-state.py").read_text()
            actual_sender = actual_sender.replace('SOCKET_PATH = "/tmp/lumora.sock"',
                                                  'SOCKET_PATH = os.environ["LUMORA_TEST_SOCKET"]')
            (fixture / "lumora-state.py").write_text(actual_sender)
            subprocess.run(
                [sys.executable, str(fixture / "nook-state.py")],
                input=json.dumps({"hook_event_name": "PreToolUse", "session_id": "compatibility-test", "cwd": str(fixture), "tool_name": "Read", "tool_input": {"file_path": "fixture"}}),
                text=True, capture_output=True, check=True, timeout=8,
                env={**os.environ, "LUMORA_TEST_SOCKET": sock_path},
            )
            connection, _ = listener.accept()
            with connection:
                payload = json.loads(connection.recv(8192))
            assert payload["session_id"] == "compatibility-test" and payload["event"] == "PreToolUse"
            assert payload["status"] == "running_tool"
        finally:
            listener.close()
    print("PASS: cached old script paths execute new senders, preserve stdin/argv/stdout/exit status, and deliver the real Claude event")
