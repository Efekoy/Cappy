# Cappy

Cappy is a native macOS contextual autocorrect project. The current milestone is the smallest InputMethodKit proof of integration: it behaves as a direct English input source and corrects `definately` to `definitely` when the following whitespace commits the word.

This phase contains no neural model, Core ML, Accessibility fallback, event tap, network access, polling, analytics, or persisted typing history.

## Current behavior

- InputMethodKit receives text for each client input session.
- Ordinary text is inserted immediately.
- The correction engine retains only the active word, bounded to 32 characters.
- After whitespace, `definately` is replaced only when the client still exposes the exact expected source range and a collapsed caret.
- Input source changes, focus/session changes, navigation commands, selections, and unexpected caret movement invalidate buffered state.
- Immediate Backspace restores `definately` and removes the committing whitespace. Immediate Undo restores `definately` while preserving it.
- Performance diagnostics contain only aggregate decision durations, never typed or replacement text.

## Build and test

Xcode can open [Cappy.xcodeproj](Cappy.xcodeproj). The command-line build uses the same Swift sources:

```sh
make test
make app
```

The packaged input method is created at `dist/Cappy.app`.

## Install and enable

Install for the current macOS user:

```sh
make install
```

Then log out and back in so macOS refreshes its input-method registry. Open **System Settings → Keyboard → Text Input → Edit**, press **+**, find **Cappy** under English, and add it. Select Cappy from the Input menu in the menu bar. If the Input menu is hidden, enable **Show Input menu in menu bar** in the same Text Input sheet.

Open TextEdit and type:

```text
I definately agree
```

The visible result should be `I definitely agree `. Press Backspace immediately after the correction to restore `I definately agree`.

Cappy does not require Accessibility or Input Monitoring permission. Remove any permissions previously granted to the older prototype if desired; this version does not use them.

To uninstall, first select another keyboard input source, then run:

```sh
make uninstall
```

The uninstall target moves the installed app to the Trash.

## Structure

- `Cappy.xcodeproj`: native macOS application target
- `Sources/Cappy/main.swift`: starts the single `IMKServer`
- `Sources/Cappy/CappyInputController.swift`: immediate passthrough, document validation, minimal replacement, and undo ledger
- `Sources/Cappy/PhaseOneCorrectionEngine.swift`: platform-independent bounded word state and hard-coded Phase 1 rule
- `Sources/Cappy/PerformanceRecorder.swift`: text-free timing aggregation
- `Resources/Info.plist`: input-source registration metadata
- `Tests/CappyTests`: engine and UTF-16 range tests
- `scripts/build-app.sh`: reproducible local package builder

## Phase 1 limits

Only the requested `definately` rule is active. Correction currently triggers on whitespace, which avoids modifying domain and path segments before safety classification exists. Clients that do not expose a valid selected range and bounded attributed substring receive normal passthrough but no correction. Compatibility still needs hands-on verification in TextEdit or Notes, Safari, Chrome, and Discord after the input source is enabled.

Phase 2 should introduce a small candidate-generation engine with dictionary lookup, bounded Damerau–Levenshtein distance, keyboard-neighbour costs, duplicate/missing letter handling, and conservative confidence classes. Contextual statistics and Core ML remain later phases.
