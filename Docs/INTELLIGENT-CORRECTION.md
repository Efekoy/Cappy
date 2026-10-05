# Audit and implementation notes

Audited all seven Swift sources, all three existing test files, Package.swift,
Xcode project/build/install scripts, resources, both training/data-generation
scripts, model metrics, and existing evaluation documentation before implementation.

Existing flow: IMK commits each character immediately. FastCorrectionEngine retains
12 recent tokens, a 32-character active token, punctuation and sentence state.
CorrectionSession reads at most 96 UTF-16 units on activation/caret resync and
validates exact source text before one replacement transaction. Its generation,
caret, range and corrected-text ledger makes immediate Backspace and Undo safe.
Backspace restores the typo and removes the final typed separator; standard Undo
restores the typo including that separator. These semantics are retained.

NSSpellChecker provides en_GB correction/guesses with two 512-entry caches.
A 100k-word/242k-pair corpus supports conservative real-word transpositions.
Core ML is a 4096-feature, 96-hidden-unit seven-action local classifier trained
on synthetic templates; it is not a general phrase generator. Neither corpus
nor classifier supplies calibrated probabilities of correctness.

Existing persistence: two bounded pair-counter dictionaries in UserDefaults;
explicit case-insensitive tokens in watched never-autocorrect.txt. Existing UI:
input-source menu opens that file, no correction popup or settings window.
Tests cover dictionary/casing, six grammar actions, punctuation, UTF-16 ranges,
native/delayed caret transactions, Backspace/Undo, protected file reload and
bounded warm latency. No representative phrase evaluation existed.

Reuse: token state, spelling caches, corpus/model, app exclusions, exact-source
validation, undo transaction, protected file and counters (migrated). New policy
ranks evidence before deciding automatic/suggestion/ignore. The former automatic
first-dictionary-guess policy is deliberately narrowed for ambiguous edits.

## Delivered correction flow

1. IMK's CorrectionSession immediately commits normal characters. On a sensible
   boundary the existing engine collects native spelling, casing, constrained
   grammar, corpus transposition, eligible Core ML and phrase candidates.
2. CorrectionCandidate carries source/replacement, an absolute UTF-16 source
   range once validated, type, base/context/personal scores, final confidence,
   evidence and a compact context signature. Stages compete by final score.
3. Protected tokens, explicit suppressed pairs and likely intentional vocabulary
   veto edits. Personal feedback adjusts the remaining candidates.
4. Automatic edits use the existing single validated source-plus-separator
   transaction and undo ledger. Suggestions leave the document untouched until
   their range, exact text, generation and caret are validated again on acceptance.
5. Presentation and learning are separate from document mutation. A failed caret
   rectangle or panel never causes an unchecked replacement or steals ordinary Tab.

## Exact thresholds and evidence policy

`CorrectionConfidence` centrally defines automatic >= 0.98, suggestion >= 0.75
and ignore < 0.75. The final score is clamped to [0, 0.9995]. These are deterministic
policy scores, not calibrated probability estimates. The Core ML wrapper and
future trainer evaluation read this same automatic threshold. The existing
synthetic classifier's medium scores are withheld because evaluation showed
false grammar suggestions; its weights were not retrained.

Case/apostrophe repairs receive 0.995. Adjacent transpositions, duplicate-letter
repairs and exact preferred dictionary splits receive 0.99. A long, one-edit
spelling with no equally nearby dictionary competitor receives 0.985. Other
eligible nearby guesses can receive 0.86; distant/highly ambiguous guesses and
lower-ranked alternatives start at 0.70. Source safety and explicit vocabulary
still override every score.

Phrase candidates start at 0.75 plus bounded corpus evidence. A phrase needs
log-likelihood gain >= 5, at least one observed supporting pair and sufficient
runner-up margin to be suggested. Automatic phrases need gain >= 7, margin >= 1.5,
and at least two pair counts >= 50,000, plus conservative real-word/boundary
eligibility. General real-word substitutions are excluded: a high-frequency
alternative alone must not turn `bale` into `sale`.

## Personalisation formula

For each applicable global/context record, let A be automatic-kept plus
suggestion-accepted counts. Positive adjustment is zero for A < 6, then
min(0.20, (A - 5) * 0.02). Subtract 0.09 per automatic undo, 0.065 per explicit
suggestion rejection, and 0.008 per ignored suggestion. Sum the global and matching
context adjustments and clamp to [-0.60, +0.20]. Three negative responses suppress
a pair when they outnumber accepts. An explicit Always Keep Here suppresses the
pair immediately. Removing the record restores baseline scoring.

A suggestion near 0.85 can become automatic after approximately twelve accepts
with no negatives. One accept gives no boost; a baseline score below 0.75 cannot
become automatic through the capped adjustment alone. An automatic keep is
inferred when the user continues typing or ends the session without undoing.

## Phrase generation and performance bounds

Use at most four of the existing twelve recent tokens, at most four choices per
token, twelve retained beams, and at most two edited tokens. Native spelling
results are reused from the existing bounded cache; phrase search performs no
additional synchronous dictionary requests. Nearby frequent short words provide
insertion/deletion/substitution/transposition candidates. A separate tightly
bounded branch relocates a neighbouring space by one character and can repair
one resulting transposition. Likelihood gains, edit penalties and runner-up
margin prune candidates. Ties use lexical ordering for reproducibility.

No phrase table contains the requested examples. Independent tests include
`How ar you`, `What ar we`, and `Can yu help`. Phrase spans cannot cross protected
tokens or punctuation, and exact document verification rejects reconstructed
spans that do not match actual whitespace. The older real-word layer generates
adjacent swaps locally and keeps its two-sided evidence requirements.

## Popup, suggestions and protection

The panel uses IMK `attributes(forCharacterIndex:lineHeightRectangle:)` with index
zero for the current selection, not Accessibility. It is a small nonactivating
NSPanel that cannot become key or main. Invalid/nonfinite/offscreen geometry
skips it. Automatic feedback shows source -> replacement with Undo for two
seconds. Suggestions show the change and Tab, with an explicit dismiss action,
for up to five seconds. Tab accepts only an active validated suggestion; Escape
rejects it. Continued typing/expiry records a weak ignore and removes it. If no
panel can be shown, no invisible suggestion intercepts Tab or earns ignore counts.

Undo restores the exact source/punctuation using the existing validated ledger.
Backspace retains the existing convention of removing the final committing
separator; Undo preserves it. After a single-word undo, Always Keep atomically
persists the source in the watched protected file and applies protection
immediately. After a phrase undo, Always Keep Here suppresses its pair/context,
without protecting ordinary constituent words. Not Now closes the prompt.

Cappy Settings in the Input menu displays Protected Words, Learned Corrections
and Observed Vocabulary. Add/remove actions require no file editing; manual
file edits still reload. UI mutations preserve existing file comments.

## Vocabulary and persistence/privacy

Technical tokens and unfamiliar spellings are observed by case, not automatically
permanently whitelisted after one use. Unknown -> observed after one intentional
boundary, -> likely intentional after eight uses. Likely intentional vocabulary
vetoes future edits of that exact case; explicit protection is immediate and uses
the existing case-insensitive file convention. Ordinary known English words are
not automatically learned as protected. Settings can remove inferred vocabulary.

The existing `never-autocorrect.txt` remains in Application Support/Cappy.
UserDefaults stores JSON-encoded records under `personalization.v2` and bounded
case-sensitive token counts under `personalization.vocabulary.v2`. Each correction
record contains only source/replacement (up to 128 UTF-16 units each), five counters,
last interaction time, optional explicit suppression and a stable FNV hash of at
most two preceding words. The hash is compact, not cryptographic anonymisation.
There are at most 512 records, 512 observed vocabulary entries, and counters cap
at 1,000. Writes coalesce after 250 ms and flush at session end/explicit settings
changes. A process crash inside that debounce window can lose the newest event.
Old acceptance/rejection dictionaries migrate without discarding preferences.

No continuous transcript, full surrounding sentences, app/document identifiers,
network inference, typed-text analytics or new permissions were added. Protected
words and correction pairs necessarily reveal those individual preferences to
someone with access to the user's local profile.

## Evaluation results (packaged release, 5 October 2026)

88 deterministic fixtures: 42 error cases and 46 valid cases. Groups cover common
misspellings, transpositions, missing/extra characters, apostrophes, spaces,
real-word errors, multi-word errors, unusual valid words, names, technical terms,
abbreviations and unchanged sentences.

- Automatic precision: 100.00%
- Automatic recall: 88.10%
- Suggestion precision: 100.00%
- Suggestion recall: 16.67%
- False positive rate: 0.00%
- False negative rate: 9.52%
- Phrase correction success: 77.78%
- Undo success: 62/62 (100%)
- Protected-word success: 10/10 (100%)

Precision counts correct proposed/applied edit events. Automatic recall counts
positive fixtures whose final automatic output matches the target. Suggestion
recall counts positive fixtures receiving a correct suggestion, whether or not a
later boundary also corrects automatically; the two recalls are not additive.
False positive rate counts altered valid fixtures. False negative rate counts
error fixtures receiving neither a complete correct automatic result nor a
correct suggestion. Undefined precision would be null, not an invented score.

These are regression fixtures, not a held-out natural-writing corpus. A score of
100% here is an observed dataset result, never a claim of universal certainty.
Raw predictions, failures and metric counts are in QUALITY-Intelligent.json.

## Release benchmarks

Milliseconds on Mac14,2, macOS 26.6.2; 2,000 warm repetitions per new operation.
Ordinary typing is the total for fourteen letters (no word boundary). Uncached
lookup samples twenty previously unused words after native-service startup.
Generation includes pruning/ranking; isolated ranking measures only corpus score.
These are engine measurements, not cross-app end-to-end UI latency.

| Operation | p50 ms | p95 ms |
|---|---:|---:|
| Ordinary typing, 14 characters | 0.004167 | 0.008792 |
| Simple spelling | 0.021042 | 0.047708 |
| Phrase generation/pruning | 0.037042 | 0.053459 |
| Phrase ranking | 0.000416 | 0.000500 |
| Personal scoring | 0.000416 | 0.000459 |
| Suggestion generation | 0.018125 | 0.079875 |
| Protected word lookup | 0.000250 | 0.000541 |
| Complete phrase boundary | 0.038916 | 0.044708 |
| Uncached spelling lookup | 0.605167 | 0.846208 |

Native first service startup and model/corpus cold loading can still take much
longer. They are prepared at process startup rather than on every character.
An intermediate benchmark found uncached native alternatives at ~27 ms p95;
that exposed a redundant query path now removed from live phrase analysis and
real-word transposition generation. The warm timings alone would have hidden it.
Raw p99/model results are in BENCHMARK-Intelligent.json.

## Validation, changed files and remaining limits

81 tests pass in debug and release, including the original suite. New coverage
includes real session phrase repairs, independent generalisation, tier edges,
Tab/Escape/expiry, learning propagation, context isolation, migration/relaunch,
settings removal, bounded storage, protected technical words, injected incorrect
SMT -> Smart undo/Always Keep, phrase pair protection, exact punctuation/Unicode
undo, stale text/range/caret/selection, unavailable geometry/text, bulk input and
protected-file comment preservation. Xcode release packaging and signing pass.

Settings layout and add/remove controls were visually verified through the real
app. An installed TextEdit smoke attempt with automated key injection did not
exercise corrections even for the existing spelling case. The current source
was confirmed as Cappy, but physical-key correction/popup behavior and browser,
Notes and messaging-app compatibility are not claimed verified by that attempt.
Manual typing verification was requested separately.

The corpus search deliberately leaves `I dint no that`, `I wan tot go`,
`Please agre` and `Please rember` unresolved in the dataset. Homophones, longer
resegmentation and richer grammar need stronger local language evidence rather
than relaxed automatic thresholds. There is no general sentence rewriter.
Caret placement is client dependent; unusable clients receive text passthrough
and retain ordinary Tab. Protection is case-insensitive when explicit, while
inferred vocabulary is case-sensitive. Acceptance remains an inference from
continued typing, and hash collisions are theoretically possible.

Changed/new implementation files:

- Sources/Cappy/CorrectionCandidate.swift: candidate model, tiers and phrase ranker.
- Sources/Cappy/FastCorrectionEngine.swift: unified ranking, tier decisions,
  source/casing protection, feedback/phrase providers and safe history boundaries.
- Sources/Cappy/CappyInputController.swift: verified suggestion transactions,
  learning, undo prompts, IMK caret geometry, settings menu and bulk passthrough.
- Sources/Cappy/CorrectionUI.swift: nonactivating overlays and three settings tabs.
- Sources/Cappy/PersonalizationStore.swift: counters, adjustments, contextual
  suppression, migration, vocabulary, debounce and protected-file editing.
- Sources/Cappy/ContextReranker.swift: shared threshold, cached corpus neighbours
  and local swap generation.
- Sources/Cappy/BenchmarkRunner.swift and main.swift: benchmarks/evaluation,
  direct settings entry point and startup model preparation.
- Tests/CappyTests/IntelligentCorrectionTests.swift: new integration/unit suite.
- Tests/CappyTests/FastCorrectionEngineTests.swift: two intentional policy changes:
  ambiguous short missing-letter edits are suggestions; three negative responses
  suppress pairs after earlier responses demote confidence.
- Resources/CorrectionEvaluation.json: grouped deterministic fixtures.
- Cappy.xcodeproj/project.pbxproj and Resources/Info.plist: register new Swift
  sources and version 0.8.0 (27).
- ML/train_reranker.py: future evaluation reads the central threshold.
- Makefile, README.md and Docs/*: reproducible commands, audit/results and limits.

Deliberately retained: IMK connection/source identities, insertion and undo ledger,
96-unit context reads, dictionary cache, protected-file watcher, terminal/code
exclusions, punctuation/Unicode safeguards, Core ML weights/features and corpus
resource. Existing tests demonstrate parity except for intentionally narrowing
unsafe dictionary guesses and changing rejection demotion/suppression policy.
No Accessibility fallback, remote model, unrestricted rewriting, model retraining
or custom replacement map was introduced.

Working examples: `teh` -> `the`, `whta` -> `what`, `Ho ware you` -> `How are you`,
`What ar you doing` -> `What are you doing`, `Can yu send it` -> `Can you send it`,
`shouldnt` -> `shouldn't`, and the existing contextual `form`/`from`, `bale`/`able`.
`Ware you` -> `Are you` remains a suggestion. `SMT`, `IFVG`, `NQ`, `CoreML` and
`QuantLab` are preserved; explicit Always Keep persists across relaunch.
