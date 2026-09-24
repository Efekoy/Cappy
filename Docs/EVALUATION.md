# Cappy correction evaluation

The automatic-correction threshold favours precision over recall. Missed edits are safer than changing a correct or intended word.

## Spelling benchmark

A bounded development evaluation used the first 3,000 alphabetic, 4–32 character misspellings from the [Birkbeck spelling-error corpus](https://titan.dcs.bbk.ac.uk/~roger/corpora.html). Corpus data is not bundled with Cappy.

Using the first macOS British English dictionary suggestion whenever it was one insertion, deletion, adjacent transposition, or nearby-key substitution produced:

- 751 attempted corrections
- 473 matching corpus targets
- 278 mismatches
- 63.0% isolated precision

That result is below Cappy's automatic-correction threshold. Long duplicate-letter errors reached 96.8% precision in this sample, so the generic automatic path is limited to that class. Short high-frequency errors such as `aggree` are handled by the reviewed common-error table. Other generated candidates are retained as future medium-confidence suggestions and are not silently applied.

This corpus has no sentence context and contains ambiguous errors, proper nouns, and attempts from very poor spellers. It is useful for rejecting an unsafe policy, but is not sufficient training data for a contextual model.

## Local contextual model

Cappy ships a 393,991-parameter multilayer perceptron as a compiled Core ML model. It hashes positional words, word fragments, and adjacent-word features from at most five tokens into 4,096 inputs, uses a 96-unit hidden layer, and ranks seven constrained actions: `KEEP` plus six exact confusion edits. It cannot generate arbitrary text. The correction engine validates the source pattern and requires at least 95% model confidence before applying an edit.

The checked-in trainer creates separate synthetic template splits with disjoint predicate and complement vocabulary. On the fixed seed it reports:

- 3,080 training examples and 630 held-out examples;
- 99.2% overall held-out accuracy;
- 100% precision among predictions at or above the 95% threshold; and
- 76.7% high-confidence coverage, including 19.5% of all held-out cases as automatic edits.

These numbers test implementation behavior and limited compositional generalization. They are not a representative natural-writing benchmark and cannot support a “best in the world” comparison. The training source and generated model are checked in so the result can be reproduced with `ML/train_reranker.py`.

## Latency

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
