#!/usr/bin/env python3
"""Run the real migration against disposable UserDefaults domains only."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
harness = r'''
import Foundation

enum PerformanceSection: String {
    case cpu, memory, battery, network
    nonisolated static let detailAll: [Self] = [.cpu, .memory, .battery, .network]
}

@main struct MigrationCheck {
    static func main() {
        let prefix = "com.conbenksl.lumora.migration-test." + UUID().uuidString
        let lingyuDomain = prefix + ".lingyu"
        let nookDomain = prefix + ".nook"
        let destinationDomain = prefix + ".destination"
        let freshDomain = prefix + ".fresh"
        let fallbackDomain = prefix + ".fallback"
        let emptyDomain = prefix + ".empty"
        let preferences = UserDefaults(suiteName: prefix)!
        defer {
            for domain in [lingyuDomain, nookDomain, destinationDomain, freshDomain,
                           fallbackDomain, emptyDomain, prefix] {
                preferences.removePersistentDomain(forName: domain)
            }
        }

        let lingyu: [String: Any] = [
            "notificationSound": "None",
            "notchAppearanceStyle": "pureBlack",
            "autoInstallHooks": false,
            "claudeHooksEnabled": false,
            "codexHooksEnabled": false,
            "opencodeHooksEnabled": true,
            "cursorHooksEnabled": false,
            "menuBarOrganizerEnabled": true,
            "screenSelectionMode": "specificScreen",
            "selectedScreenIdentifier": Data([1, 2, 3]),
            "nook_shortcut_bindings": Data([4, 5, 6]),
            "musicAudioReactiveGlowEnabled": true,
            "musicAudioCaptureWasGranted": true,
            "musicAudioCaptureDebugBuildFingerprint": "old-build",
            "mixpanel_distinct_id": "old-analytics-id",
            "NSStatusItem Preferred Position Nook.MenuBar.Toggle": 20,
            "unknownFutureKey": "must-not-copy",
        ]
        let nook: [String: Any] = [
            "notificationSound": "Pop",
            "autoInstallHooks": true,
            "claudeHooksEnabled": true,
            "codexHooksEnabled": true,
            "opencodeHooksEnabled": false,
            "cursorHooksEnabled": true,
            "menuBarOrganizerEnabled": false,
            "screenSelectionMode": "automatic",
            "nook_shortcut_bindings": Data([10, 11, 12]),
            "musicEdgeGlowEnabled": true,
        ]
        preferences.setPersistentDomain(lingyu, forName: lingyuDomain)
        preferences.setPersistentDomain(nook, forName: nookDomain)
        preferences.setPersistentDomain([
            "notchAppearanceStyle": "liquidGlass",
            "menuBarOrganizerEnabled": true,
            "lumora_shortcut_bindings": Data([7, 8, 9]),
            "destinationOnly": "preserve",
        ], forName: destinationDomain)
        // Registered fallback values must not mask persisted legacy settings.
        preferences.register(defaults: ["autoInstallHooks": true])
        AppSettings.migrateLegacyPreferencesIfNeeded(
            using: preferences, from: [lingyuDomain, nookDomain], to: destinationDomain
        )
        var result = preferences.persistentDomain(forName: destinationDomain)!
        assert(result["notificationSound"] as? String == "None")
        assert(result["autoInstallHooks"] as? Bool == false)
        assert(result["claudeHooksEnabled"] as? Bool == false)
        assert(result["codexHooksEnabled"] as? Bool == false)
        assert(result["opencodeHooksEnabled"] as? Bool == true)
        assert(result["cursorHooksEnabled"] as? Bool == false)
        assert(result["notchAppearanceStyle"] as? String == "liquidGlass")
        assert(result["menuBarOrganizerEnabled"] as? Bool == true,
               "Existing Lumora choices must not be overwritten")
        assert(result["destinationOnly"] as? String == "preserve")
        assert(result["screenSelectionMode"] as? String == "specificScreen")
        assert(result["selectedScreenIdentifier"] as? Data == Data([1, 2, 3]))
        assert(result["lumora_shortcut_bindings"] as? Data == Data([7, 8, 9]))
        assert(result["musicEdgeGlowEnabled"] == nil,
               "Older original settings must not leak into preferred fork settings")
        for key in ["musicAudioReactiveGlowEnabled", "musicAudioCaptureWasGranted",
                    "musicAudioCaptureDebugBuildFingerprint", "mixpanel_distinct_id",
                    "NSStatusItem Preferred Position Nook.MenuBar.Toggle", "unknownFutureKey",
                    "nook_shortcut_bindings"] {
            assert(result[key] == nil, "Unexpected migration of \(key)")
        }

        AppSettings.migrateLegacyPreferencesIfNeeded(
            using: preferences, from: [lingyuDomain, nookDomain], to: freshDomain
        )
        let fresh = preferences.persistentDomain(forName: freshDomain)!
        assert(fresh["lumora_shortcut_bindings"] as? Data == Data([4, 5, 6]),
               "Old shortcut key must migrate to Lumora's key")
        assert(fresh["menuBarOrganizerEnabled"] as? Bool == false,
               "New identity must remain visible until it obtains its own AX permission")
        AppSettings.migrateLegacyPreferencesIfNeeded(
            using: preferences, from: [prefix + ".missing-lingyu", nookDomain], to: fallbackDomain
        )
        let fallback = preferences.persistentDomain(forName: fallbackDomain)!
        assert(fallback["notificationSound"] as? String == "Pop")
        assert(fallback["autoInstallHooks"] as? Bool == true)
        assert(fallback["menuBarOrganizerEnabled"] as? Bool == false)
        assert(fallback["screenSelectionMode"] as? String == "automatic")
        assert(fallback["lumora_shortcut_bindings"] as? Data == Data([10, 11, 12]))

        result.removeValue(forKey: "notificationSound")
        result["menuBarOrganizerEnabled"] = false
        preferences.setPersistentDomain(result, forName: destinationDomain)
        AppSettings.migrateLegacyPreferencesIfNeeded(
            using: preferences, from: [lingyuDomain, nookDomain], to: destinationDomain
        )
        assert(preferences.persistentDomain(forName: destinationDomain)!["notificationSound"] == nil,
               "Later launches must not restore a setting the new app removed")
        assert(preferences.persistentDomain(forName: destinationDomain)!["menuBarOrganizerEnabled"] as? Bool == false)
        for domain in [lingyuDomain, nookDomain] {
            AppSettings.migrateLegacyPreferencesIfNeeded(
                using: preferences, from: [domain], to: domain
            )
        }
        assert(NSDictionary(dictionary: preferences.persistentDomain(forName: lingyuDomain)!)
            .isEqual(to: lingyu), "Migration changed the previous fork's preferences")
        assert(NSDictionary(dictionary: preferences.persistentDomain(forName: nookDomain)!)
            .isEqual(to: nook), "Migration changed the original app's preferences")
        AppSettings.migrateLegacyPreferencesIfNeeded(
            using: preferences, from: [prefix + ".missing"], to: emptyDomain
        )
        assert(preferences.persistentDomain(forName: emptyDomain)?.count == 1,
               "Missing legacy settings should only record migration completion")
        print("PASS: preferred/fallback legacy domains, allowlist, shortcut mapping, existing values, consent boundary, one-time behavior, isolated domains")
    }
}
'''

# Launch rejection must happen before integrations acquire shared ownership.
delegate = (repo / "Lumora/App/AppDelegate.swift").read_text()
guard = delegate.split("private func ensurePreviousVersionIsNotRunning()", 1)[1].split(
    "private func ensureSingleInstance()", 1
)[0]
assert '"com.conbenksl.lingyu"' in guard
assert '"com.oaimgo.nook"' in guard
assert '"com.conbenksl.lumora"' not in guard, "Lumora must not reject itself as a previous version"
assert delegate.index("!ensurePreviousVersionIsNotRunning()") < delegate.index("AppSettings.registerDefaults()")
assert delegate.index("AppSettings.registerDefaults()") < delegate.index("HookInstaller.installIfNeeded()")
assert "guard windowManager != nil else { return }" in delegate

with tempfile.TemporaryDirectory(prefix="lumora-preferences-check-") as directory:
    directory = Path(directory)
    main = directory / "MigrationCheck.swift"
    main.write_text(harness)
    executable = directory / "migration-check"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-default-isolation", "MainActor", "-o", str(executable),
        str(repo / "Lumora/Core/Settings.swift"), str(main),
    ], check=True)
    subprocess.run([str(executable)], check=True)
