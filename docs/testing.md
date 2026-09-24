# Testing

Lumora uses an Xcode unit-test target named `LumoraTests`. The target is hosted by
`Lumora.app` so tests can access internal app modules through `@testable import
Lumora`, but the test suite should stay focused on deterministic domain logic.

Run the local suite with:

```bash
xcodebuild test -project Lumora.xcodeproj -scheme Lumora -configuration Debug -derivedDataPath build/TestDerivedData -destination 'platform=macOS'
```

For a clean local run, quit any running `Lumora.app`, then reset the test
DerivedData first:

```bash
rm -rf build/TestDerivedData
xcodebuild test -project Lumora.xcodeproj -scheme Lumora -configuration Debug -derivedDataPath build/TestDerivedData -destination 'platform=macOS'
```

The test target is intentionally not parallelizable in the shared scheme. The
app owns singleton state and local process resources such as `/tmp/lumora.sock`,
so parallel host launches can make Xcode report an early test-runner exit even
when individual tests pass.

## Current Coverage

- Provider adapters:
  - `ClaudeChatItemAdapterTests` covers Claude JSONL/history conversion, tool
    status propagation, and rejected `AskUserQuestion` structured fallback.
  - `CodexHookAdapterTests` covers Codex hook alias decoding, provider error
    detection, and legacy payload detection.
  - `CodexTranscriptParserTests` covers transcript sync filtering, including
    `/clear` lower-bound behavior for missing or malformed timestamps.
  - `CursorSessionStateReducerTests` covers Cursor lifecycle transitions and
    dangling tool finalization.
  - `OpencodeChatItemAdapterTests` covers opencode raw bus envelopes through
    the chat-item adapter boundary, including message-relative ordering and
    bash metadata error detection.
- Service boundaries:
  - `MediaRemoteSnapshotTests` covers now-playing metadata and artwork mapping.
- Shared state pipeline:
  - `MarkdownBlockParserTests` covers independent parsing of headings, lists,
    quotes, fenced code, and aligned tables.
  - `ChatItemUpdateReducerTests` covers insert/update ordering, duplicate
    prompt preservation, and tool status updates.
  - `SessionStateTests` covers terminal approval state exposure.
  - `SessionStoreCodexLifecycleTests` covers Codex stop cleanup and completion
    notification behavior.

The native MediaRemote binding can also be smoke-tested without starting a player;
the check reports only whether metadata is present and does not print track details:

```bash
python3 LumoraTests/check_media_remote_client.py
```

## Adding Tests

Keep provider-specific behavior in provider-specific test files. Shared tests
should only assert provider-agnostic contracts such as `ChatItemUpdateReducer`
ordering or `SessionState` phase behavior.

Prefer fixtures at the provider boundary:

- Claude: build `ChatMessage` values and call `ClaudeChatItemAdapter`.
- Codex: decode hook envelopes or feed JSONL rows into `CodexTranscriptParser`.
- Cursor: feed `CursorSessionEvent` into `CursorSessionStateReducer` unless the
  hook envelope shape itself is under test.
- opencode: build `OpencodeHookEnvelope` values and call
  `OpencodeChatItemAdapter.adaptAndConvert(_:)` so hook parsing and chat-item
  conversion stay covered together.

Avoid UI assertions in this target unless the view has first been split into a
small deterministic model or formatter. The goal of these tests is to catch
regressions in session state, provider parsing, and chat-item transformation
without requiring a live terminal, agent process, or music session.

## Renamed Build and Resource Checks

The branding change also renames resources that are loaded at runtime. Check
Xcode inputs, Objective-C headers, scheme names, icon entries, and bundled sound
and hook resources before building:

```bash
python3 scripts/check-branding.py
python3 scripts/check-localization.py
python3 LumoraTests/check_menu_bar_organizer.py
```

After packaging, check the actual bundle as well:

```bash
python3 scripts/check-branding.py --app /path/to/Lumora.app
```

These checks do not prove startup, hook delivery, animation behavior, or macOS
permissions. Verify those with the installed app. Existing settings and hook
migration should preserve unrelated agent configuration. A newly signed app
may require a fresh Accessibility grant; verify the current installed bundle.
