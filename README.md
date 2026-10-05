# Cappy

Cappy is a fast, private macOS contextual autocorrect. It combines the macOS British English dictionary, a local word-frequency model, and a tiny Core ML grammar reranker and applies corrections when a space commits a word or Tab completes it. Enter never triggers corrections.

The model runs entirely on-device. Cappy uses no network access, Accessibility fallback, event tap, polling, analytics, or persisted typing history.

## Current behavior

- Characters pass through immediately. Space/Tab boundaries generate bounded candidates from the native British English dictionary, existing grammar rules, corpus statistics and a local Core ML classifier.
- All stages compete through shared confidence scoring: **automatic ≥ 0.98**, **suggestion ≥ 0.75**, otherwise leave the text unchanged. Scores are conservative policy values, not calibrated correctness probabilities.
- Phrase search uses up to four recent tokens, four options per token, a twelve-beam search and at most two token edits. It can move a misplaced space as in `Ho ware you` → `How are you`, and repairs `What ar you doing` and `Can yu send it` with corpus evidence. It never scans a document for phrases.
- Strong transpositions, apostrophe-only repairs, exact dictionary-recommended splits and unambiguous nearby spellings retain the automatic path. Ambiguous dictionary guesses and two-edit guesses are deliberately restricted.
- Real-word transpositions retain two-sided statistical validation; nearby swaps are generated locally rather than querying native alternatives for every ordinary word.
- Corrections and suggestions verify exact UTF-16 source text, a collapsed selection, expected caret and generation before replacing anything. Punctuation is preserved. URLs, emails, paths, identifiers, numbers, mixed case and uppercase abbreviations stay protected; terminal/code-editor exclusions remain.
- A nonactivating caret popup shows automatic corrections and Undo for two seconds. A suggestion leaves text unchanged: **Tab accepts**, **Escape dismisses**, and normal typing or five-second expiry removes it. Unavailable IMK caret geometry disables the popup and suggestion interception gracefully, without Accessibility permission.
- Immediate **Backspace** restores the typed source and removes its committing separator; immediate **Undo** restores it with that separator. Both validate the corrected document range first.
- After a single-word undo, **Always Keep** adds the original token to the existing watched `never-autocorrect.txt` file. Phrase undos offer **Always Keep Here**, suppressing that pair/context without whitelisting neighbouring words.
- Automatic keeps/undos and suggestion accepts/rejections/ignores update bounded local counters. Acceptance boosts start only after six accepts; explicit negative responses have much more weight than ignored suggestions. Learning changes subsequent decisions.
- Repeated unfamiliar or technical vocabulary is observed case-sensitively, becomes likely intentional after eight uses, and can be explicitly protected immediately. One unusual occurrence never permanently whitelists a word.
- **Cappy Settings…** in the Input menu provides Protected Words, Learned Corrections and Observed Vocabulary tabs, with add/remove actions. Manual file edits still work and comments survive UI edits.
- Enter, line breaks and bulk pasted text pass through without correction. Ordinary Tab continues to the client when no visible valid suggestion is active.
- Timing diagnostics contain aggregate durations only. No typed text leaves Cappy, and no continuous typing transcript is stored.

See [the implementation report](Docs/INTELLIGENT-CORRECTION.md) for architecture, formulas, evaluation and limitations.

## Build and test

Xcode can open [Cappy.xcodeproj](Cappy.xcodeproj). The command-line build uses the same Swift sources:

```sh
make test
make app
make benchmark
make evaluate
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
- `Sources/Cappy/PersonalizationStore.swift`: bounded feedback/vocabulary learning, migration and watched protected-word persistence
- `Sources/Cappy/CorrectionCandidate.swift`: central tiers, candidate metadata and bounded corpus phrase search
- `Sources/Cappy/CorrectionUI.swift`: nonactivating caret overlay and personalisation settings
- `Resources/CorrectionEvaluation.json`: deterministic grouped quality fixtures
- `Resources/NeverAutocorrect.txt`: initial protected-word list, copied once without overwriting user edits
- `Sources/Cappy/PerformanceRecorder.swift`: text-free timing aggregation
- `Sources/Cappy/ContextReranker.swift`: bounded feature extraction and local Core ML inference
- `scripts/build-language-model.py`: builds statistical word/pair frequencies from published corpus counts
- `Resources/LanguageFrequencies.tsv`: bundled, quantised language-frequency data (no typo mappings)
- `ML/train_reranker.py`: reproducible synthetic-data trainer and Core ML exporter
- `Docs/EVALUATION.md`: quality methodology, limitations, and measured results
- `Docs/BENCHMARK.json`: historical benchmark output from the development Mac
- `Docs/BENCHMARK-General.json`: historical packaged 0.7.0 spelling/context timings
- `Docs/BENCHMARK-Intelligent.json`: 0.8.0 release p50/p95/p99 benchmarks
- `Docs/QUALITY-Intelligent.json`: separate automatic/suggestion quality and integrity results
- `Resources/Info.plist`: input-source registration metadata
- `Tests/CappyTests`: engine and UTF-16 range tests
- `scripts/generate-icons.swift`: a vector template keycap with a transparent C cutout, standard/Retina TIFF alternatives, and a blue .icns app icon
- `scripts/build-app.sh`: reproducible local package builder
- `scripts/install-app.sh`: in-place installer and input-service refresher

## Current limits

Correction triggers on spaces or a Tab command, so the active word remains unchanged until a word boundary. This avoids modifying domain and path segments before the whole token can be classified. Clients that do not expose a valid selected range and bounded attributed substring receive normal passthrough but no correction. Integration tests cover native replacement-caret behavior, delayed post-insertion caret queries, Space/Return/Tab commands, undo, and unavailable document text. Real keyboard compatibility still needs hands-on verification in TextEdit or Notes, Safari, Chrome, and Discord after the input source is enabled.

The Core ML model still covers six constrained grammar edits. The new corpus phrase ranker is deliberately conservative, not a general grammar rewriter. The evaluation currently leaves `I dint no that`, `I wan tot go`, `Please agre` and `Please rember` unresolved. An 88-case regression dataset reports no incorrect automatic edits, but cannot establish natural-writing accuracy or calibrate confidence. Native dictionary cold start, client geometry and real keyboard behavior vary across applications; see the implementation report for the exact verified scope.

Open settings directly from a development bundle with `dist/Cappy.app/Contents/MacOS/Cappy --settings`.


## Correct written text on demand

With Cappy selected as your input source, press **⌘⌥⇧C** (Command–Option–Shift–C), or choose **Correct Written Text** in Cappy’s input menu. Cappy corrects selected text; without a selection, it reviews the current paragraph **before the caret**. Put the caret at the end to review the whole paragraph, or select a passage spanning multiple paragraphs.

The command uses the existing local spelling and contextual phrase pipeline. It applies only candidates meeting the automatic confidence threshold (0.98), respects protected words and excluded apps, and preserves separators, punctuation, emoji and following text. It is not a general-purpose grammar or style rewrite. No Accessibility permission, clipboard access, network request, or saved paragraph is involved.

A temporary caret popup reports the correction count and offers **Undo**. Immediate standard Undo is also handled when the client forwards that command to Cappy; ordinary native undo remains client-dependent. Undo restores the exact original text, with the caret at the end of the restored range. Further typing/navigation ends Cappy’s batch undo window. Fields that do not expose document text through InputMethodKit cannot use this command. The bounded review accepts up to 4,096 UTF-16 units and abandons the entire result after a one-second budget; a single native dictionary query cannot be interrupted mid-call. If another app reserves the shortcut, use the input-menu action.
