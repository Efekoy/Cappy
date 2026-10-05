# Manual correction shortcut — Cappy 0.8.1 (28)

Press **Command–Option–Shift–C** with Cappy active, or use **Correct Written Text** in its input menu. Selected text is reviewed; otherwise Cappy reviews the paragraph before the caret. Put the caret at the end to review the entire paragraph. The existing exclusions for Terminal, iTerm, Xcode and VS Code still apply.

## Implementation

The shortcut uses Carbon’s event dispatcher, registered only while a Cappy input client is active, with exclusive registration to avoid silently sharing the shortcut with another registered owner. It does not change the existing IMK typing event routing. The pattern is consistent with the [HotKey reference implementation](https://github.com/soffes/HotKey/blob/master/Sources/HotKey/HotKeysController.swift). A failed registration is logged without text; the input menu remains available.

`CorrectionSession.correctWrittenText` captures a bounded attributed snapshot through IMK. `ManualTextCorrection` runs a copy of the existing engine over that snapshot, retaining native dictionary, contextual phrase ranking, personal confidence, and protected-word policies. Only automatic-tier candidates (≥ 0.98) are applied. Vocabulary observation is disabled for this review so repeatedly reviewing the same passage does not teach artificial intentional usage. A synthetic final space completes the final token and is removed before returning. Each candidate’s exact source suffix must match the in-memory passage.

Before one attributed replacement, the session rechecks the selection and exact attributed source. Unchanged text, unavailable clients, invalid ranges, a changed selection/source/formatting, oversized input, or timeout cause no replacement. The limit is 4,096 UTF-16 units, with a one-second analysis budget checked between engine calls and again before returning. A native dictionary query cannot be interrupted mid-call. Formatting, separators, emoji, punctuation and following document text are retained.

A five-second nonactivating caret panel reports the correction count and offers Undo. Undo verifies the corrected attributed range and caret, restoring the original attributed snapshot. Immediate `undo:` is also supported when the client forwards it; native host Undo remains app-dependent. Further typing, navigation, deactivation or session invalidation ends Cappy’s batch undo window. As with normal text replacement, the caret ends at the end of the replacement; undo restores text and formatting, not the previous selection.

The original passage is held only in the active in-memory undo ledger. It is never written into personal learning storage or logs. No clipboard, Accessibility, network, or transcript storage is added. Existing personal correction preferences affect scoring; batch review does not infer acceptance/rejection for every included word.

## Validation

- 102 release tests pass, including all existing tests and 21 new manual-review tests.
- New coverage includes multiple spelling repairs, unfinished final words, corpus phrase repairs, Unicode/spacing/punctuation, selected passages, paragraph scope, middle-of-document carets, protected/structured tokens, medium-confidence abstention, excluded/unavailable clients, changed source/caret/formatting, exact attributed undo, timeout, length bounds and impossible ranges.
- Manual phrase tests cover `Ho ware you` → `How are you`, `What ar you doing` → `What are you doing`, and `Can yu send it` → `Can you send it`, through the existing corpus ranker.
- The packaged 88-case correction evaluation retains 100% automatic precision, 88.10% automatic recall, zero false positives, 62/62 successful undos, and 10/10 protected-word successes.
- Release benchmarks (100 warm samples) are recorded in [BENCHMARK-ManualReview.json](BENCHMARK-ManualReview.json). A 37-character review using cached native candidates and the corpus pipeline measured p50 0.222 ms and p95 0.243 ms. A deterministic 43-character generation run measured p50 0.045 ms and p95 0.049 ms. These are controlled in-process timings, not cold-start or cross-app latency guarantees.
- The release bundle builds, signs and installs as 0.8.1 (28); installed and built executables match. Runtime hotkey registration returned success. Automated macOS key injection did not deliver a hotkey callback, so physical-key behavior and the caret panel in Chrome, Discord, Codex and TextEdit remain unverified. A physical test was requested; no result was received during this pass.

## Limitations

This command fixes high-confidence spelling and supported contextual phrases. It does not promise unrestricted grammar or style rewriting. Medium/low-confidence candidates remain untouched. IMK clients that do not expose the selected range and surrounding text cannot be corrected without another access mechanism. No Accessibility fallback was added. Shortcut customization, broader paragraph rewriting and bulk feedback UX are outside this change.
