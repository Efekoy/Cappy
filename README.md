# Cappy

Cappy is a fast, private macOS contextual autocorrect. It combines the macOS British English dictionary, a local word-frequency model, and a tiny Core ML grammar reranker and applies corrections when a space commits a word or Tab completes it. Enter never triggers corrections.

The model runs entirely on-device. Cappy uses no network access, analytics, or persisted typing history. Standard typing corrections use InputMethodKit. Optional cross-app word highlights use read-only Accessibility queries; no global keyboard or mouse events are monitored.

## Current behavior

- Characters pass through immediately. Space/Tab boundaries generate bounded candidates from the native British English dictionary, existing grammar rules, corpus statistics and a local Core ML classifier.
- When the dictionary's guesses compete, they are ranked by corpus frequency, the neighbouring words and common typing slips (a dropped double letter, swapped letters, a neighbouring key). One guess must clearly win: `tiink` → `think` (vs `tink`/`twink`). A short ambiguous typo can be settled by the next word, as in `agre with` → `agree with`. A word the user has undone is never revisited. When the dictionary has no guess at all, a single close common corpus word that the dictionary recognises may be used, as in `defitnetaly` → `definitely`. Apostrophe-free contractions that the dictionary accepts as words (`thats`, `whats`, `youre`) gain their apostrophe. Forms that are also words (`cant`, `wont`, `were`, `well`, `its`) do not.
- The space key never waits on the dictionary. Uncached spell-checker lookups (5–150 ms) run on a background queue. When a lookup is pending, or the host's text has not caught up with recent keys (common in Chromium and Electron apps), that space is decided at the next 0.15 s pause in typing, from the settled document and its sentence context. Text typed after the space is rewritten unchanged. Enter, navigation and clicks drop pending decisions.
- All stages compete through shared confidence scoring: **automatic ≥ 0.98**, **suggestion ≥ 0.75**, otherwise leave the text unchanged. Scores are conservative policy values, not calibrated correctness probabilities.
- Phrase search uses up to four recent tokens, four options per token, a twelve-beam search and at most two token edits. It can move a misplaced space as in `Ho ware you` → `How are you`, and repairs `What ar you doing` and `Can yu send it` with corpus evidence. It never scans a document for phrases.
- `lets` becomes `Let’s` at sentence starts; invitation phrases such as `so lets go` gain the apostrophe while ordinary verbs such as `she lets me` stay intact.
- Strong transpositions, apostrophe-only repairs, exact dictionary-recommended splits and unambiguous nearby spellings retain the automatic path. Ambiguous dictionary guesses and two-edit guesses are deliberately restricted.
- Real-word transpositions retain two-sided statistical validation; nearby swaps are generated locally rather than querying native alternatives for every ordinary word.
- Corrections and suggestions verify exact UTF-16 source text, a collapsed selection, expected caret and generation before replacing anything. Punctuation is preserved. URLs, emails, paths, identifiers, numbers, mixed case and uppercase abbreviations stay protected; terminal/code-editor exclusions remain.
- A compact nonactivating Liquid Glass capsule follows the corrected range when the host exposes reliable geometry, with a mouse-transparent blue highlight. Automatic corrections show **Undo** for 2.5 seconds, including while you continue typing. A faint, borderless blue fill marks the replaced word for three seconds. **Control–Option–Z (⌃⌥Z)** undoes the visible correction and preserves text typed afterward; it is handled only by the active Cappy input source, without registering a global shortcut. Suggestions leave text unchanged: **Tab accepts**, **Escape dismisses**, and typing or five-second expiry removes them. After two explicit rejections, the capsule asks **Stop autocorrecting “source”? Yes**; confirming shows a brief learned confirmation. A caret anchor is used when range geometry is unavailable, and the focused editor or window when neither exists, so the capsule appears in every app (see below). Native input-method highlights need no extra permission. For editors that omit word bounds, enable **Cappy → Enable Cross-App Highlights…** and grant Cappy Accessibility access; its fallback only reads the focused editor’s matching text range and bounds. See [overlay handoff](Docs/CORRECTION-OVERLAY.md) for the manual test checklist.
- Immediate **Backspace** restores the typed source and removes its committing separator; immediate **Undo** restores it with that separator. Both validate the corrected document range first. The capsule’s Undo button and ⌃⌥Z also work during continued typing until the capsule expires; navigation or external edits dismiss it.
- After two rejections, confirming **Yes** adds a single original token to the watched `never-autocorrect.txt` file. For a phrase, confirmation suppresses that pair/context without protecting neighbouring words.
- Automatic keeps/undos and suggestion accepts/rejections/ignores update bounded local counters. Acceptance boosts start only after six accepts; rejections never lower confidence or silently suppress corrections. After two explicit rejections, Cappy asks before saving a suppression preference.
- Repeated unfamiliar or technical vocabulary is observed case-sensitively, becomes likely intentional after eight uses, and can be explicitly protected immediately. Observations never silently suppress corrections.
- **Cappy Settings…** in the Input menu provides Protected Words, Learned Corrections and Observed Vocabulary tabs, with add/remove actions. Manual file edits still work and comments survive UI edits.
- Enter, line breaks and bulk pasted text pass through without correction. Tab is consumed when it accepts a visible valid suggestion or applies a correction; otherwise it continues to the client for normal focus navigation. Shift-Tab keeps backward navigation.
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

`make install` replaces the installed bundle, stops the old Cappy process, re-registers the input source, and refreshes the input-menu artwork. It preserves the InputMethodKit connection broker. Cappy launches the updated executable on the next key event while retaining the same input-source selection. If an already-running app stops receiving input after an update, save unfinished drafts and fully quit and reopen that app to recreate its input connection; switching input sources alone may not reset it.

Open TextEdit and type each line, including the trailing space:

```text
I definately agree
hello chat welocme
dont worry
```

The visible results should be `I definitely agree `, `Hello chat welcome `, and `Don't worry `. Press Backspace immediately after a correction to restore the original word.

Standard InputMethodKit corrections do not require Accessibility permission. For precise blue highlights and capsule placement in Discord, Codex and other web editors, grant Cappy access in **System Settings → Privacy & Security → Accessibility**. Cappy's input menu and settings include an enable button.

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

Chrome receives its original character events directly; Cappy reads bounded context and validates corrections at spaces, rather than inserting each ordinary character through IMK. Tab still accepts an active suggestion and otherwise passes through. Shortcuts, navigation, excluded applications and Option composition retain their native events. Passive suggestion expiry does not demote `i` → `I`; explicit undo, rejection and protection still take precedence.

The Core ML model still covers six constrained grammar edits. The new corpus phrase ranker is deliberately conservative, not a general grammar rewriter. The evaluation currently leaves `I dint no that`, `I wan tot go`, `Please agre` and `Please rember` unresolved. An 88-case regression dataset reports no incorrect automatic edits, but cannot establish natural-writing accuracy or calibrate confidence. Native dictionary cold start, client geometry and real keyboard behavior vary across applications; see the implementation report for the exact verified scope.

Open settings directly from a development bundle with `dist/Cappy.app/Contents/MacOS/Cappy --settings`.

## Feedback in every app

The capsule picks the most precise anchor the app offers: the corrected word's bounds (IMK, then Accessibility text ranges or markers walked back from the caret), then the caret, then the focused editor's frame, then the app's frontmost window (from the window server, no permission needed). It therefore appears in Chrome, Claude, Discord, Notion and other Chromium/Electron apps even though they return no word geometry; there it sits just below the text field (or inside the lower-left corner of large editors). The blue word highlight still requires exact word bounds and is never guessed. Chrome answers text-marker queries with the whole field's frame; Cappy rejects that rather than highlighting the entire field.

Run `Cappy --diagnose-accessibility <bundle-id>` from the installed bundle (launched with `open -n -a ... --args`) for permission, focused-editor, caret and frame status without printing editor contents.
