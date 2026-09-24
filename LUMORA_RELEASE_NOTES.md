# Lumora Release Notes

Lumora (灵屿) is a locally developed macOS notch application.

## 1.0.0

Local build: 2026092303.

- Rename the application, executable, Xcode target, internal module, and runtime
  resources to Lumora, with a distinct app identifier and the custom island icon.
- Keep the Chinese interface, animation refinements, hover handling, and menu bar
  overlap support.
- Migrate existing preferences and agent connections to the Lumora names, socket,
  and hook paths while preserving unrelated agent configuration.
- Keep small compatibility entry points for hook commands cached by running agent
  sessions. New configurations register only Lumora, without duplicate callbacks.
- Maintain Lumora release notes and disable automatic update checks. Preserve
  applicable licenses and third-party notices.

This is a local build record. It does not indicate a public release, Apple
notarization, or a published download. macOS permissions apply to the installed
application identity and may need to be granted again after migration.
