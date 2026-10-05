# Cappy

Cappy is a fast, private macOS contextual autocorrect. It combines the macOS British English dictionary, a local word-frequency model, and a tiny Core ML grammar reranker and applies corrections when a space commits a word or Tab completes it. Enter never triggers corrections.

The model runs entirely on-device. Cappy uses no network access, Accessibility fallback, event tap, polling, analytics, or persisted typing history.

## Current behavior

- InputMethodKit receives text for each client input session.
- Ordinary text is inserted immediately. At a word boundary, Cappy validates the source range before writing and commits a correction plus its separator in one insertion. This avoids stale post-insertion caret reads and keeps the caret after the separator.
- The correction engine retains only the active word, up to four trailing punctuation characters, and at most twelve nearby words plus sentence-boundary state. It reads at most 96 UTF-16 units of left context when a client session starts.
- General spelling corrections use macOS's British English dictionary recommendations, rather than a hardcoded typo/replacement table. Adjacent transpositions, omitted/extra letters, and substitutions are supported; short words allow one edit and longer words allow two. Examples include `whta` → `what`, `yuor` → `your`, `doign` → `doing`, and `difrent` → `different`.
- Dictionary suggestions that restore an apostrophe without changing the letters take precedence, including `shouldnt` → `shouldn't`. Otherwise macOS's automatic recommendation takes precedence over ranked guesses. Exact missing-space splits use the same dictionary path.
- A bundled statistical model contains frequencies for 100,000 words and 242,052 neighbouring word pairs. It considers generic adjacent-letter swaps in valid words only when both surrounding word pairs support the change strongly, including `be bale to` → `be able to` and `heard form you` → `heard from you`. It preserves `a bale of hay` and `The form you need` in the checked-in tests.
- Trailing punctuation is preserved during correction (`whta? ` → `what? `). Cappy waits for a following space or Tab before correcting so it can protect domains such as `whta.com`.
- A lowercase first word is capitalised at the start of a document or after `.`, `!`, `?`, or a newline.
- Bounded contextual rules handle high-confidence valid-word errors including `Your going` → `You're going`, `there car` → `their car`, and `should of` → `should have`.
- A 394k-parameter Core ML reranker examines at most five nearby tokens and chooses only among `KEEP` and six validated edit types. The engine applies a model edit only above a 95% confidence threshold and verifies that its source text matches the requested edit.
- Explicit exceptions are stored in `~/Library/Application Support/Cappy/never-autocorrect.txt`, one word per line, ignoring case. Open it from **Edit words Cappy should keep…** in the Cappy Input menu. Saved edits update the running session; listed words are protected from spelling, capitalisation, and contextual rewrites. `Cappy` is included initially.
- Immediate undo is learned locally. After the same correction pair is rejected twice, Cappy suppresses it; only bounded pair counters are persisted.
- Corrections are disabled in known terminal and code-editor apps, while token checks suppress URLs, email addresses, paths, identifiers, numbers, and mixed-case names.
- Contextual substitutions wait for enough nearby words to distinguish cases such as `They're going to` from the valid possessive phrase `their going rate`.
- A replacement is applied only when the client still exposes the exact expected source range and a collapsed caret.
- Input source changes, focus/session changes, navigation commands, selections, and unexpected caret movement invalidate buffered state. Return and line breaks pass through without correcting text, so sending a message cannot apply an unchecked correction. Tab corrects the completed word before passing the original command to the app.
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
- `Sources/Cappy/FastCorrectionEngine.swift`: bounded word state, sentence-boundary tracking, and dictionary-backed spelling
- `Sources/Cappy/PersonalizationStore.swift`: local rejection counters and watched never-autocorrect vocabulary
- `Resources/NeverAutocorrect.txt`: initial protected-word list, copied once without overwriting user edits
- `Sources/Cappy/PerformanceRecorder.swift`: text-free timing aggregation
- `Sources/Cappy/ContextReranker.swift`: bounded feature extraction and local Core ML inference
- `scripts/build-language-model.py`: builds statistical word/pair frequencies from published corpus counts
- `Resources/LanguageFrequencies.tsv`: bundled, quantised language-frequency data (no typo mappings)
- `ML/train_reranker.py`: reproducible synthetic-data trainer and Core ML exporter
- `Docs/EVALUATION.md`: quality methodology, limitations, and measured results
- `Docs/BENCHMARK.json`: historical benchmark output from the development Mac
- `Docs/BENCHMARK-General.json`: packaged 0.7.0 spelling/context verification and timings
- `Resources/Info.plist`: input-source registration metadata
- `Tests/CappyTests`: engine and UTF-16 range tests
- `scripts/generate-icons.swift`: a vector template keycap with a transparent C cutout, standard/Retina TIFF alternatives, and a blue .icns app icon
- `scripts/build-app.sh`: reproducible local package builder
- `scripts/install-app.sh`: in-place installer and input-service refresher

## Current limits

Correction triggers on spaces or a Tab command, so the active word remains unchanged until a word boundary. This avoids modifying domain and path segments before the whole token can be classified. Clients that do not expose a valid selected range and bounded attributed substring receive normal passthrough but no correction. Integration tests cover native replacement-caret behavior, delayed post-insertion caret queries, Space/Return/Tab commands, undo, and unavailable document text. Real keyboard compatibility still needs hands-on verification in TextEdit or Notes, Safari, Chrome, and Discord after the input source is enabled.

The Core ML grammar model covers six confusion edits rather than unrestricted rewriting. The frequency model adds contextual real-word transpositions, but it is not a general grammar rewriter and cannot correct every possible mistake. Dictionary-backed spelling can change unfamiliar names or choose the wrong word when several candidates are plausible; immediate undo remains available. Its 99.2% held-out accuracy and 100% high-confidence precision are from a synthetic template split, so they do not establish performance on normal writing or superiority to other autocorrect systems. The external Birkbeck result measures spelling candidates without sentence context. See [Docs/EVALUATION.md](Docs/EVALUATION.md) before interpreting the numbers.
