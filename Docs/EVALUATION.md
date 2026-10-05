# Cappy correction evaluation

## Current policy (0.8.0)

See [INTELLIGENT-CORRECTION.md](INTELLIGENT-CORRECTION.md) for the full implementation report. `make evaluate` runs the grouped 88-case fixture dataset in `Resources/CorrectionEvaluation.json` against the packaged dictionary, corpus and Core ML model. Raw results are in `QUALITY-Intelligent.json`; release performance is in `BENCHMARK-Intelligent.json`. Historical results below describe earlier policies and are not current accuracy claims. The runtime automatic threshold is now 0.98; the trainer reads this central Swift constant for future evaluations. Existing model weights and historical metrics have not been retrained or relabelled.

## Historical general-spelling policy (0.7.0)

Spelling is no longer limited to a typo table or long duplicate-letter errors. Cappy uses the native British English automatic-correction recommendation and otherwise the top ranked dictionary guess. A generic Damerau-Levenshtein filter allows one edit for 2–4 character words and two edits for longer words, including adjacent transpositions. Exact missing-space splits are also accepted. This increases coverage at the cost of potentially choosing the wrong plausible spelling; the historical precision numbers below do not establish this release's accuracy.

Real-word transpositions use 100,000 unigram and 242,052 bigram log-counts derived from [Peter Norvig's published corpus data](https://norvig.com/ngrams/), originating in the Google Web Trillion Word Corpus. This is statistical language data, not a list of misspellings. Both replacement bigrams must appear at least 50,000 times in the source counts, left-context evidence must improve by at least 4×, right conditional evidence by at least 1.25×, and their combined improvement by at least 100×. Unseen source pairs use a count floor of 1,000. Valid-word substitutions other than adjacent-letter swaps are excluded: development tests found that two-sided bigram scoring alone could turn valid `bale` into `sale` and `sail` into `fail`.

Generate the frequency resource with `python3 scripts/build-language-model.py /path/to/count_1w.txt /path/to/count_2w.txt`. The script keeps the first 100,000 alphabetic/contraction unigrams, retains bigrams within that vocabulary, merges repeated word pairs, and quantises natural log counts to hundredths. Inputs are downloaded for development only. No network service is used while typing.

The integration suite covers the user's `whta`, `yuor`, `doign`, and contextual `bale` examples, an independent `form`/`from` transposition, valid rare words/phrases, trailing punctuation, undo, caret latency, source-range validation, and URLs/email addresses. These regression tests establish the listed behaviours, not universal correction accuracy.

## Historical policy (before 0.7.0)

The old automatic-correction threshold favoured precision over recall. That missed ordinary typos and was replaced in 0.7.0.

## Spelling benchmark

A bounded development evaluation used the first 3,000 alphabetic, 4–32 character misspellings from the [Birkbeck spelling-error corpus](https://titan.dcs.bbk.ac.uk/~roger/corpora.html). Corpus data is not bundled with Cappy.

Using the first macOS British English dictionary suggestion whenever it was one insertion, deletion, adjacent transposition, or nearby-key substitution produced:

- 751 attempted corrections
- 473 matching corpus targets
- 278 mismatches
- 63.0% isolated precision

That result was below the old automatic-correction threshold. Long duplicate-letter errors reached 96.8% precision in this sample, so the old generic automatic path was limited to that class. Short high-frequency errors such as `aggree` were handled by a reviewed common-error table. That table and restriction have now been removed.

This corpus has no sentence context and contains ambiguous errors, proper nouns, and attempts from very poor spellers. It is useful for rejecting an unsafe policy, but is not sufficient training data for a contextual model.

## Local contextual model

Cappy ships a 393,991-parameter multilayer perceptron as a compiled Core ML model. It hashes positional words, word fragments, and adjacent-word features from at most five tokens into 4,096 inputs, uses a 96-unit hidden layer, and ranks seven constrained actions: `KEEP` plus six exact confusion edits. It cannot generate arbitrary text. The correction engine validates the source pattern and requires at least 95% model confidence before applying an edit.

The checked-in trainer creates separate synthetic template splits with disjoint predicate and complement vocabulary. On the fixed seed it reports:

- 3,080 training examples and 630 held-out examples;
- 99.2% overall held-out accuracy;
- 100% precision among predictions at or above the 95% threshold; and
- 76.7% high-confidence coverage, including 19.5% of all held-out cases as automatic edits.

These numbers test implementation behavior and limited compositional generalization. They are not a representative natural-writing benchmark and cannot support a “best in the world” comparison. The training source and generated model are checked in so the result can be reproduced with `ML/train_reranker.py`.

## Current packaged verification

`Docs/BENCHMARK-General.json` records a 0.7.0 packaged-app run. It confirms that the bundled frequency model loads, the user's sample spelling errors correct, contextual `bale`/`able` and `form`/`from` corrections apply, and valid hay/domain/email examples remain unchanged. On this run, model cold loading took about 266 ms once at startup; the cached spelling path measured 0.011 ms p95. These are warm repeated-word timings, not a latency claim for cold dictionary requests or real typing in every client app.

The 0.7.2 test run passes 52 tests, including missing-apostrophe restoration, explicit word protection against spelling/capitalisation/context edits, and live reload after an atomic file save. The native Fn popup remains unverified because the UI automation tool cannot press Fn.

## Historical latency

`make benchmark` builds the release app and runs its embedded model. On the development MacBook Air (Mac14,2) running macOS 26.6.2, one 10,000-iteration deterministic run measured 0.0061 ms p95. The 393,991-parameter Core ML reranker measured 0.502 ms p95 and 0.511 ms p99 over 1,000 warm inferences with `.all` compute units. Cold model loading measured 4.22 ms in that run. Raw output is checked in at `Docs/BENCHMARK.json`.

The Core ML result adds roughly half a millisecond at a whitespace boundary, not on every keystroke. Timings vary by hardware, OS state, and build.

## Context and safety checks

The checked-in quality suite covers:

- high-confidence contextual corrections;
- valid possessive and existential phrases that must remain unchanged;
- URLs, email addresses, paths, identifiers, UUIDs, and version strings;
- local rejection learning; and
- deterministic p95 latency below 1 ms on the development Mac.

The missing-space stage accepts only the dictionary's first suggestion, requires exactly two parts of at least two characters, and requires that removing the proposed space reproduces the original token exactly. Tests reject lower-ranked and inexact split suggestions.

The quality suite also injects model decisions into the engine to verify thresholding and source-pattern validation. A future release still needs evaluation on a representative, redistributable natural-writing corpus before comparative quality claims are justified.
