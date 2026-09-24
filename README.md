# Cappy

Cappy is a fast, private macOS contextual autocorrect. It combines conservative rules with a tiny local Core ML reranker and applies corrections when the following whitespace commits a word.

The model runs entirely on-device. Cappy uses no network access, Accessibility fallback, event tap, polling, analytics, or persisted typing history.

## Current behavior

- InputMethodKit receives text for each client input session.
- Ordinary text is inserted immediately.
- The correction engine retains only the active word plus sentence-boundary state. It reads at most 96 UTF-16 units of left context when a client session starts.
- High-confidence spelling corrections include `definately` → `definitely`, `welocme` → `welcome`, `teh`/`tge`/`yhe` → `the`, and a small extensible common-typo table.
- Unknown words are checked against macOS's offline British English dictionary. Corpus evaluation showed that isolated one-edit guesses are too ambiguous for automatic replacement, so generic auto-correction is limited to long duplicate-letter errors; common short errors use the curated high-confidence table.
- A missing space is restored when the dictionary's first suggestion is exactly the original token split into two words, including `Can'tget` → `Can't get`. Approximate and lower-ranked splits are left unchanged.
- High-confidence missing apostrophes such as `dont` → `don't`, `cant` → `can't`, and `youre` → `you're` are corrected without a model.
- A lowercase first word is capitalised at the start of a document or after `.`, `!`, `?`, or a newline.
- Bounded contextual rules handle high-confidence valid-word errors including `Your going` → `You're going`, `there car` → `their car`, and `should of` → `should have`.
- A 394k-parameter Core ML reranker examines at most five nearby tokens and chooses only among `KEEP` and six validated edit types. The engine applies a model edit only above a 95% confidence threshold and verifies that its source text matches the requested edit.
- Immediate undo is learned locally. After the same correction pair is rejected twice, Cappy suppresses it; only bounded pair counters are persisted.
- Corrections are disabled in known terminal and code-editor apps, while token checks suppress URLs, email addresses, paths, identifiers, numbers, and mixed-case names.
- Contextual substitutions wait for enough nearby words to distinguish cases such as `They're going to` from the valid possessive phrase `their going rate`.
- A replacement is applied only when the client still exposes the exact expected source range and a collapsed caret.
- Input source changes, focus/session changes, navigation commands, selections, and unexpected caret movement invalidate buffered state.
- Immediate Backspace restores `definately` and removes the committing whitespace. Immediate Undo restores `definately` while preserving it.
- Performance diagnostics contain only aggregate decision durations, never typed or replacement text.

## Build and test

Xcode can open [Cappy.xcodeproj](Cappy.xcodeproj). The command-line build uses the same Swift sources:

```sh
make test
make app
make benchmark
```

The packaged input method is created at `dist/Cappy.app`.

## Install and enable

Install for the current macOS user:

```sh
make install
```

On the first installation, open **System Settings → Keyboard → Text Input → Edit**, press **+**, find **Cappy** under English, and add it. If the new source is not visible yet, log out and back in once so macOS rebuilds its input-method registry. Select Cappy from the Input menu in the menu bar. If the Input menu is hidden, enable **Show Input menu in menu bar** in the same Text Input sheet.

Later development updates do not require a logout or restart. `make install` replaces the installed bundle, stops the old Cappy process, re-registers the input source, and refreshes the per-user text-input services. Cappy launches the updated executable on the next key event while retaining the same input-source selection.

Open TextEdit and type each line, including the trailing space:

```text
I definately agree
hello chat welocme
dont worry
```

The visible results should be `I definitely agree `, `Hello chat welcome `, and `Don't worry `. Press Backspace immediately after a correction to restore the original word.

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
- `Sources/Cappy/FastCorrectionEngine.swift`: platform-independent bounded word state, sentence-boundary tracking, and high-confidence correction tables
- `Sources/Cappy/PerformanceRecorder.swift`: text-free timing aggregation
- `Sources/Cappy/ContextReranker.swift`: bounded feature extraction and local Core ML inference
- `ML/train_reranker.py`: reproducible synthetic-data trainer and Core ML exporter
- `Docs/EVALUATION.md`: quality methodology, limitations, and measured results
- `Docs/BENCHMARK.json`: raw benchmark output from the development Mac
- `Resources/Info.plist`: input-source registration metadata
- `Tests/CappyTests`: engine and UTF-16 range tests
- `scripts/build-app.sh`: reproducible local package builder
- `scripts/install-app.sh`: in-place installer and input-service refresher

## Current limits

Correction currently triggers on whitespace, so the active word remains unchanged until Space, Return, or another whitespace character is typed. This avoids modifying domain and path segments before the complete safety classifier exists. Clients that do not expose a valid selected range and bounded attributed substring receive normal passthrough but no correction. Compatibility still needs hands-on verification in TextEdit or Notes, Safari, Chrome, and Discord after the input source is enabled.

The contextual model currently covers six confusion edits rather than unrestricted rewriting. Its 99.2% held-out accuracy and 100% high-confidence precision are from a synthetic template split, so they do not establish performance on normal writing or superiority to other autocorrect systems. The external Birkbeck result measures spelling candidates without sentence context. See [Docs/EVALUATION.md](Docs/EVALUATION.md) before interpreting the numbers.
