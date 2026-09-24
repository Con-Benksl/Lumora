//
//  OpencodeHookInstaller.swift
//  Lumora
//
//  Installs the bundled OpenCode plugin and migrates its previous local name.
//  Event forwarding remains in Resources/opencode-plugin/index.js.
//

import Foundation

struct OpencodeHookInstaller {
    private static var configDir: URL { AgentPathsResolver.directory(for: .opencode) }
    private static var pluginDir: URL { configDir.appendingPathComponent("plugins/lumora") }
    private static var legacyPluginDir: URL { configDir.appendingPathComponent("plugins/nook") }

    /// Prefer the same JSONC file OpenCode already uses.
    private static var configFile: URL {
        let jsonc = configDir.appendingPathComponent("opencode.jsonc")
        return FileManager.default.fileExists(atPath: jsonc.path)
            ? jsonc : configDir.appendingPathComponent("opencode.json")
    }

    static func installIfNeeded() {
        guard AgentPathsResolver.isInstalled(.opencode) else { return }
        do {
            // Validate first so malformed user configuration is never replaced.
            let data = try configurationData()
            let updated = try updatedConfiguration(data, pluginDirectory: pluginDir, installing: true)
            guard try copyPluginFiles() else { return }
            try updated.write(to: configFile, options: .atomic)
            try retainLegacyPluginEntryPoint()
        } catch {
            NSLog("Lumora: OpenCode plugin installation failed: %@", error.localizedDescription)
        }
    }

    static func uninstall() {
        do {
            let updated = try updatedConfiguration(try configurationData(), pluginDirectory: pluginDir, installing: false)
            try updated.write(to: configFile, options: .atomic)
            removeOwnedPluginFiles(at: pluginDir, expectedName: "lumora")
            removeLegacyPluginFiles()
        } catch {
            NSLog("Lumora: OpenCode plugin removal failed: %@", error.localizedDescription)
        }
    }

    static func isInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: pluginDir.appendingPathComponent("package.json").path),
              FileManager.default.fileExists(atPath: pluginDir.appendingPathComponent("index.js").path),
              let data = try? Data(contentsOf: configFile),
              let json = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any],
              let entries = json["plugin"] as? [String] else { return false }
        return entries.contains { normalizedPluginPath($0, relativeTo: configDir) == pluginDir.path }
    }

    private static func configurationData() throws -> Data? {
        FileManager.default.fileExists(atPath: configFile.path) ? try Data(contentsOf: configFile) : nil
    }

    /// JSONC is parsed before editing; all other settings and plugins survive.
    /// Serialization normalizes comments and formatting, never invalid data.
    nonisolated static func updatedConfiguration(
        _ original: Data?, pluginDirectory: URL, installing: Bool
    ) throws -> Data {
        var json: [String: Any] = [:]
        if let original {
            guard let value = try JSONSerialization.jsonObject(with: original, options: [.json5Allowed]) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            json = value
        }
        guard json["plugin"] == nil || json["plugin"] is [String] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let configDirectory = pluginDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let legacyDirectory = pluginDirectory.deletingLastPathComponent().appendingPathComponent("nook")
        let ownedPaths = [pluginDirectory.standardizedFileURL.path, legacyDirectory.standardizedFileURL.path]
        var entries = (json["plugin"] as? [String] ?? []).filter {
            !ownedPaths.contains(normalizedPluginPath($0, relativeTo: configDirectory))
        }
        if installing { entries.append(pluginDirectory.path) }
        if entries.isEmpty { json.removeValue(forKey: "plugin") }
        else { json["plugin"] = entries }
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    nonisolated private static func normalizedPluginPath(_ entry: String, relativeTo directory: URL) -> String {
        if entry.hasPrefix("file:"), let url = URL(string: entry), url.isFileURL {
            return url.standardizedFileURL.path
        }
        if entry.hasPrefix("/") { return URL(fileURLWithPath: entry).standardizedFileURL.path }
        if entry.hasPrefix("./") || entry.hasPrefix("../") {
            return directory.appendingPathComponent(entry).standardizedFileURL.path
        }
        // Package identifiers are not local files and must be left alone.
        return entry
    }

    private static func copyPluginFiles() throws -> Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        for base in [resources.appendingPathComponent("opencode-plugin"), resources] {
            guard let packageData = try? Data(contentsOf: base.appendingPathComponent("package.json")),
                  let package = try? JSONSerialization.jsonObject(with: packageData) as? [String: Any],
                  package["name"] as? String == "lumora",
                  let script = try? Data(contentsOf: base.appendingPathComponent("index.js")) else { continue }
            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            try script.write(to: pluginDir.appendingPathComponent("index.js"), options: .atomic)
            try packageData.write(to: pluginDir.appendingPathComponent("package.json"), options: .atomic)
            return true
        }
        return false
    }

    /// Keep an existing module path importable while registering only the new one.
    /// Modules already evaluated in memory require an OpenCode session restart.
    private static func retainLegacyPluginEntryPoint() throws {
        let packageURL = legacyPluginDir.appendingPathComponent("package.json")
        let scriptURL = legacyPluginDir.appendingPathComponent("index.js")
        guard let data = try? Data(contentsOf: packageURL),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              package["name"] as? String == "nook" else { return }
        let script = "// Lumora compatibility entry point for a previously registered module.\nexport { default } from '../lumora/index.js';\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    }

    private static func removeLegacyPluginFiles() {
        removeOwnedPluginFiles(at: legacyPluginDir, expectedName: "nook")
    }

    /// Remove only this plugin's known files; preserve any unrelated files in the directory.
    private static func removeOwnedPluginFiles(at directory: URL, expectedName: String) {
        let packageURL = directory.appendingPathComponent("package.json")
        let scriptURL = directory.appendingPathComponent("index.js")
        guard let data = try? Data(contentsOf: packageURL),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              package["name"] as? String == expectedName,
              let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              script.contains("/tmp/\(expectedName).sock") || script.contains("export { default } from '../lumora/index.js'") else { return }
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: packageURL)
        if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
