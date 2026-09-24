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

## Context and safety checks

The checked-in quality suite covers:

- high-confidence contextual corrections;
- valid possessive and existential phrases that must remain unchanged;
- URLs, email addresses, paths, identifiers, UUIDs, and version strings;
- local rejection learning; and
- deterministic p95 latency below 1 ms on the development Mac.

The optional Core ML reranker remains gated on a representative, redistributable contextual corpus with separate training and test splits. An untrained model or a model evaluated on its training examples will not be shipped.
