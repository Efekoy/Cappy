# AutoCaps

AutoCaps is a tiny native macOS menu-bar utility providing sentence capitalisation, double-space periods, conservative missing-apostrophe correction, standalone `i` → `I`, and Apple-powered typo suggestions.

Press Control-Option-Command-A (`⌃⌥⌘A`) to turn all AutoCaps processing on or off globally. The menu-bar item shows the current state.

It uses only AppKit, Core Graphics, Accessibility, and ServiceManagement. It has no network code, analytics, typing log, clipboard access, third-party dependencies, web views, or polling during normal operation.

Typo Fixes is on by default and can be switched off under Settings in the menu bar. AutoCaps asks macOS's `NSSpellChecker` about a single completed word when you press Space, Return, or safe punctuation; it does not call the checker on every keystroke. Only short, single-word suggestions within two edits are applied. Existing contraction rules take priority. URL/email/code token joiners (including `.` and `@`), mixed-case words, and manually capitalised names are skipped. A word before a period is held briefly: it is corrected only if Space or Return follows, so domains are not changed. System spelling suggestions can still be wrong; switch Typo Fixes off if they interfere with a workflow.

## Build and run

Requires macOS 13 or later and current Xcode Command Line Tools.

```sh
make test
make app
open dist/AutoCaps.app
```

For reliable Launch at Login behavior, install it before first-run setup:

```sh
make install
open /Applications/AutoCaps.app
```

Grant Accessibility and Input Monitoring when prompted. The setup window checks permissions once per second only while that window is visible; normal operation has no timer. After setup, AutoCaps has no Dock icon and lives in the menu bar.

The build is locally signed with a stable designated requirement. The first build using this identity needs one permission grant; subsequent local rebuilds retain the same identity and should not create repeated Accessibility/Input Monitoring entries. A Developer ID certificate remains the preferred choice if the app is ever distributed to another Mac.

## Privacy and safety

- Typed text is never saved or transmitted.
- Focus is checked before each text key; `AXSecureTextField` controls are untouched.
- Only after focus/navigation changes, AutoCaps requests at most 64 characters immediately before the cursor. It never requests the complete field value.
- The current-word buffer is capped at 32 characters.
- Generated events carry a private event tag and are ignored by AutoCaps.
- Command, Control, Option, and Function-modified keystrokes are never transformed.

The editable safe-contraction table is `TextEngine.contractionDictionary` in `Sources/AutoCaps/TextEngine.swift`.
The list now includes the requested `cant` → `can't`, `ill` → `I'll`, and `its` → `it's`. The latter two are ambiguous English words, so disable Contractions in the menu if those corrections are unwanted in a particular workflow.

## Compatibility and limitations

Standard AppKit fields use native cursor ranges. Chromium/Electron editors such as Discord and Codex use bounded web text-marker ranges. Some rich web editors (including some Google Docs modes), terminal emulators, remote desktops, games, canvas editors, and apps using secure event input may still suppress event taps or expose no cursor information. AutoCaps then avoids guessing after focus changes.
Discord's composer can omit cursor context when switching DMs. AutoCaps no longer assumes a new DM's composer is empty simply because it was clicked; it waits for explicit empty context or a known-empty composer state. This avoids capitalising inside existing drafts, though an empty composer with no Accessibility cursor data may not capitalise its first letter.

Multi-character input-method events are passed through unchanged to avoid corrupting composed or non-Latin input.

AutoCaps is automatically bypassed while Microsoft's Windows App (`com.microsoft.rdc.macos`) is frontmost, preventing generated replacement keystrokes from being forwarded incorrectly to a remote PC. The global toggle hotkey still works while Windows App is active.

## Tests

The transformation engine is independent of the global event layer:

```sh
swift test
```
