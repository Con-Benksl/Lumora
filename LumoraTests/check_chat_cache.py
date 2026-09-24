#!/usr/bin/env python3
"""Run ChatView's real init/task code with lightweight Swift stubs.

Requires Python 3 and the Swift compiler (macOS Command Line Tools suffice).
This checks cache visibility and sync decisions, not SwiftUI rendering.
Run from any directory: python3 /path/to/LumoraTests/check_chat_cache.py
"""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
chat = (repo / "Lumora/UI/Views/ChatView.swift").read_text()
init_source = chat[chat.index('    init('):chat.index('    /// Whether')]
task_source = chat.split('        .task {\n', 1)[1].split('\n        }\n        .onReceive', 1)[0]
prefix = r'''
import Foundation
@propertyWrapper struct State<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    init(initialValue: Value) { wrappedValue = initialValue }
}
@propertyWrapper struct ObservedObject<Value> { var wrappedValue: Value }
struct Color {
    static let white = Color()
    func opacity(_ value: Double) -> Color { self }
}
struct Animation { static func easeOut(duration: Double) -> Animation { Animation() } }
func withAnimation(_ animation: Animation, _ updates: () -> Void) { updates() }
enum Provider { case codex, cursor, claude }
struct ChatHistoryItem: Equatable { let id: String }
struct SessionState {
    let provider: Provider
    let chatItems: [ChatHistoryItem]
    let cwd = "/unchanged/path"
}
struct SessionMonitor {}
struct NotchViewModel {}
@MainActor final class ChatHistoryManager {
    static let shared = ChatHistoryManager()
    var histories: [String: [ChatHistoryItem]] = [:]
    var loads: [(String, Bool)] = []
    var loaded = Set<String>()
    func history(for id: String) -> [ChatHistoryItem] { histories[id] ?? [] }
    func isLoaded(sessionId: String) -> Bool { loaded.contains(sessionId) }
    func loadFromFile(sessionId: String, cwd: String, force: Bool) async {
        guard force || !loaded.contains(sessionId) else { return }
        loads.append((sessionId, force))
        await Task.yield()
        loaded.insert(sessionId)
        histories[sessionId] = (histories[sessionId] ?? []) + [ChatHistoryItem(id: "synced")]
    }
}
@MainActor struct ChatHarness {
    let sessionId: String
    let initialSession: SessionState
    let sessionMonitor: SessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    let primaryTextColor: Color
    let secondaryTextColor: Color
    @State var session: SessionState
    @State var history: [ChatHistoryItem]
    @State var isLoading: Bool
    @State var hasLoadedOnce: Bool
'''
suffix = r'''
}
@main struct Checks {
    @MainActor static func main() async {
        let manager = ChatHistoryManager.shared
        let cached = [ChatHistoryItem(id: "cached")]
        manager.histories["codex"] = cached
        manager.loaded.insert("codex")
        func view(_ provider: Provider, _ items: [ChatHistoryItem], _ id: String) -> ChatHarness {
            ChatHarness(sessionId: id, initialSession: SessionState(provider: provider, chatItems: items), sessionMonitor: SessionMonitor(), viewModel: NotchViewModel())
        }
        var cachedView = view(.codex, cached, "codex")
        precondition(cachedView.history == cached && !cachedView.isLoading, "Codex cache must be visible immediately")
        await cachedView.load()
        precondition(manager.loads.count == 1 && manager.loads[0].1, "Cached Codex must force a background transcript sync")
        precondition(cachedView.history.count == 2 && !cachedView.isLoading, "Refreshed messages must replace the cached view")
        await cachedView.load()
        precondition(manager.loads.count == 1, "Same view must not duplicate its initial task")
        var reopened = view(.codex, cachedView.history, "codex")
        precondition(!reopened.isLoading, "Reopening must keep cached history visible")
        await reopened.load()
        precondition(manager.loads.count == 2 && manager.loads[1].1, "Reopening must still synchronize")
        var emptyView = view(.codex, [], "empty")
        precondition(emptyView.isLoading, "An uncached Codex session still needs a loading state")
        await emptyView.load()
        precondition(!emptyView.isLoading && emptyView.history.count == 1, "Initial load must finish normally")
        manager.histories["claude"] = cached
        var other = view(.claude, [], "claude")
        precondition(!other.isLoading && other.history == cached)
        await other.load()
        precondition(manager.loads.count == 3, "Other providers keep the existing cache behavior")
        let cursor = view(.cursor, [], "cursor")
        precondition(!cursor.isLoading, "Empty Cursor session keeps its existing non-loading behavior")
        print("PASS: actual ChatView init/task lifecycle, cached and uncached Codex, reopen refresh, other providers")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='lumora-chat-cache-') as tmp:
    tmp = Path(tmp)
    harness = tmp / 'ChatHarness.swift'
    harness.write_text(prefix + init_source + '\n    mutating func load() async {\n' + task_source + '\n    }\n' + suffix)
    binary = tmp / 'chat-check'
    subprocess.run(['swiftc', '-parse-as-library', str(harness), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
