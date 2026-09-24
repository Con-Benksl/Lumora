//
//  ShortcutStore.swift
//  Lumora
//
//  Persistence and validation for keyboard shortcut bindings
//

import Foundation
import Combine

@MainActor
class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    @Published var bindings: [ShortcutAction: [KeyCombination]] = [:]

    private let storageKey = AppSettings.shortcutsKey

    private init() {
        load()
    }

    // MARK: - Load / Save

    func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ShortcutBindings].self, from: data) else {
            resetToDefaults()
            return
        }
        var map: [ShortcutAction: [KeyCombination]] = [:]
        for item in decoded {
            map[item.action] = item.combinations
        }
        bindings = map
    }

    func save() {
        let items = bindings.map { ShortcutBindings(action: $0.key, combinations: $0.value) }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        objectWillChange.send()
    }

    func combinations(for action: ShortcutAction) -> [KeyCombination] {
        bindings[action] ?? action.defaultCombinations
    }

    // MARK: - Conflict Detection

    /// Returns the action that already uses this combination, or nil if free.
    func findConflict(_ combo: KeyCombination, excluding: ShortcutAction? = nil) -> ShortcutAction? {
        for (action, combos) in bindings {
            if let excluded = excluding, action == excluded { continue }
            if combos.contains(combo) { return action }
        }
        // Also check default bindings for actions not yet customized
        for action in ShortcutAction.allCases {
            if let excluded = excluding, action == excluded { continue }
            if bindings[action] != nil { continue } // already checked above
            if action.defaultCombinations.contains(combo) { return action }
        }
        return nil
    }

    /// Adds a combination to an action. Returns false if conflict.
    @discardableResult
    func addCombination(_ combo: KeyCombination, to action: ShortcutAction) -> Bool {
        if let conflict = findConflict(combo, excluding: action) {
            print("Shortcut conflict: \(combo) already bound to \(conflict.displayName)")
            return false
        }
        var combos = bindings[action] ?? action.defaultCombinations
        if !combos.contains(combo) {
            combos.append(combo)
            bindings[action] = combos
            save()
        }
        return true
    }

    /// Removes the last combination from an action.
    func removeLastCombination(from action: ShortcutAction) {
        var combos = bindings[action] ?? action.defaultCombinations
        guard !combos.isEmpty else { return }
        combos.removeLast()
        bindings[action] = combos
        save()
    }

    /// Removes a specific combination from an action.
    func removeCombination(_ combo: KeyCombination, from action: ShortcutAction) {
        var combos = bindings[action] ?? action.defaultCombinations
        combos.removeAll { $0 == combo }
        bindings[action] = combos
        save()
    }

    func resetToDefaults() {
        bindings = [:]
        save()
    }

    func isCustomized(_ action: ShortcutAction) -> Bool {
        bindings[action] != nil
    }
}
