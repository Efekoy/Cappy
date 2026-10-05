#!/usr/bin/env python3
"""Build bounded frequency data, never typo/replacement pairs, for Cappy.

Sources: https://norvig.com/ngrams/ (Google Web Trillion Word Corpus counts).
Download count_1w.txt and count_2w.txt there, then pass their paths here.
"""
import argparse
import math
import re
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('unigrams', type=Path)
parser.add_argument('bigrams', type=Path)
args = parser.parse_args()
valid = re.compile(r"[a-z]+(?:'[a-z]+)?$")
words = {}
for line in args.unigrams.read_text().splitlines():
    word, count = line.split('\t')
    if valid.fullmatch(word) and len(words) < 100_000:
        words[word] = int(count)
pairs = {}
for line in args.bigrams.read_text().splitlines():
    pair, count = line.split('\t')
    parts = pair.split(' ')
    if len(parts) == 2 and all(word in words for word in parts):
        pairs[pair] = pairs.get(pair, 0) + int(count)
output = Path(__file__).resolve().parents[1] / 'Resources' / 'LanguageFrequencies.tsv'
with output.open('w') as stream:
    stream.write('# Cappy log-counts; source: https://norvig.com/ngrams/\n')
    # Quantised log counts keep the bundled statistical data compact.
    for key, count in sorted((words | pairs).items()):
        stream.write(f'{key}\t{round(math.log(count) * 100)}\n')
print(f'{len(words)} words, {len(pairs)} word pairs, {output.stat().st_size} bytes')
