#!/usr/bin/env python3
"""Train Cappy's tiny constrained contextual reranker and export Core ML."""

from __future__ import annotations

import argparse
import json
import re
import time
from pathlib import Path

import coremltools as ct
import numpy as np
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder

FEATURE_COUNT = 4096
HIDDEN_COUNT = 96
CLASSES = [
    "KEEP",
    "YOUR_TO_YOURE",
    "THEIR_TO_THEYRE",
    "THERE_TO_THEYRE",
    "THERE_TO_THEIR",
    "OF_TO_HAVE",
    "ITS_TO_ITS_APOSTROPHE",
]
# Keep evaluation aligned with the single runtime threshold definition.
_CONFIDENCE_SOURCE = Path(__file__).resolve().parents[1] / "Sources/Cappy/CorrectionCandidate.swift"
AUTOMATIC_THRESHOLD = float(re.search(r"static let automatic = ([0-9.]+)", _CONFIDENCE_SOURCE.read_text()).group(1))


def fnv1a(text: str) -> int:
    value = 14695981039346656037
    for byte in text.encode("utf-8"):
        value ^= byte
        value = (value * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return value


def features(tokens: list[str]) -> np.ndarray:
    tokens = [token.lower() for token in tokens[-5:]]
    result = np.zeros(FEATURE_COUNT, dtype=np.float32)
    result[fnv1a("bias") % FEATURE_COUNT] = 1
    for index, token in enumerate(tokens):
        relative = index - len(tokens)
        result[fnv1a(f"u:{relative}:{token}") % FEATURE_COUNT] += 1
        for width in range(2, min(4, len(token)) + 1):
            result[fnv1a(f"p:{relative}:{token[:width]}") % FEATURE_COUNT] += 1
            result[fnv1a(f"s:{relative}:{token[-width:]}") % FEATURE_COUNT] += 1
            for start in range(len(token) - width + 1):
                result[fnv1a(f"c:{relative}:{token[start:start + width]}") % FEATURE_COUNT] += 1
    for index in range(1, len(tokens)):
        relative = index - len(tokens)
        result[fnv1a(f"b:{relative}:{tokens[index - 1]}:{tokens[index]}") % FEATURE_COUNT] += 1
    return result


def examples(seed: int = 7) -> tuple[list[tuple[list[str], int]], list[tuple[list[str], int]]]:
    rng = np.random.default_rng(seed)
    train_predicates = ["going", "doing", "coming", "leaving", "ready", "right", "wrong", "late", "great"]
    test_predicates = ["returning", "waiting", "working", "early", "certain"]
    train_complements = ["home", "now", "soon", "again", "away", "back", "to", "here"]
    test_complements = ["today", "outside", "tomorrow", "there"]
    possessive_nouns = ["car", "phone", "house", "name", "team", "friend", "work", "idea", "room"]
    ambiguous_nouns = ["rate", "shoes", "system", "cost", "plan", "schedule"]
    prefixes = [[], ["i", "think"], ["they", "said"], ["maybe"], ["today"]]

    def build(predicates: list[str], complements: list[str], repetitions: int) -> list[tuple[list[str], int]]:
        rows: list[tuple[list[str], int]] = []
        for _ in range(repetitions):
            predicate = rng.choice(predicates).item()
            complement = rng.choice(complements).item()
            prefix = list(prefixes[int(rng.integers(len(prefixes)))])
            rows.extend([
                (prefix + ["your", predicate, complement], 1),
                (prefix + ["their", predicate, complement], 2),
                (prefix + ["there", predicate, complement], 3),
                (prefix + ["its", predicate, complement], 6),
            ])
            noun = rng.choice(possessive_nouns).item()
            rows.extend([
                (prefix + ["your", noun], 0),
                (prefix + ["their", noun], 0),
                (prefix + ["its", noun], 0),
                (prefix + ["there", "is", noun], 0),
            ])
            modifier = rng.choice(ambiguous_nouns).item()
            rows.extend([
                (prefix + ["your", predicate, modifier], 0),
                (prefix + ["their", predicate, modifier], 0),
                (prefix + ["its", predicate, modifier], 0),
            ])
            modal = rng.choice(["should", "could", "would"]).item()
            rows.append((prefix + [modal, "of"], 5))
            rows.append((prefix + [modal, "offer"], 0))
            rows.append((prefix + ["there", noun], 4))
        rng.shuffle(rows)
        return rows

    return build(train_predicates, train_complements, 220), build(test_predicates, test_complements, 45)


def matrix(rows: list[tuple[list[str], int]]) -> tuple[np.ndarray, np.ndarray]:
    x = np.stack([features(tokens) for tokens, _ in rows])
    y = np.array([label for _, label in rows], dtype=np.int64)
    return x, y


def train(x: np.ndarray, y: np.ndarray, seed: int = 7) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    rng = np.random.default_rng(seed)
    w1 = rng.normal(0, 0.025, (FEATURE_COUNT, HIDDEN_COUNT)).astype(np.float32)
    b1 = np.zeros(HIDDEN_COUNT, dtype=np.float32)
    w2 = rng.normal(0, 0.025, (HIDDEN_COUNT, len(CLASSES))).astype(np.float32)
    b2 = np.zeros(len(CLASSES), dtype=np.float32)
    learning_rate = 0.04
    batch_size = 128

    for epoch in range(90):
        order = rng.permutation(len(x))
        for start in range(0, len(x), batch_size):
            batch = order[start : start + batch_size]
            xb, yb = x[batch], y[batch]
            hidden_pre = xb @ w1 + b1
            hidden = np.maximum(hidden_pre, 0)
            logits = hidden @ w2 + b2
            logits -= logits.max(axis=1, keepdims=True)
            probabilities = np.exp(logits)
            probabilities /= probabilities.sum(axis=1, keepdims=True)
            probabilities[np.arange(len(batch)), yb] -= 1
            probabilities /= len(batch)
            dw2 = hidden.T @ probabilities
            db2 = probabilities.sum(axis=0)
            dh = probabilities @ w2.T
            dh[hidden_pre <= 0] = 0
            dw1 = xb.T @ dh
            db1 = dh.sum(axis=0)
            w1 -= learning_rate * dw1
            b1 -= learning_rate * db1
            w2 -= learning_rate * dw2
            b2 -= learning_rate * db2
        if epoch in (45, 70):
            learning_rate *= 0.3
    return w1, b1, w2, b2


def probabilities(x: np.ndarray, weights: tuple[np.ndarray, ...]) -> np.ndarray:
    w1, b1, w2, b2 = weights
    hidden = np.maximum(x @ w1 + b1, 0)
    logits = hidden @ w2 + b2
    logits -= logits.max(axis=1, keepdims=True)
    result = np.exp(logits)
    return result / result.sum(axis=1, keepdims=True)


def export_model(weights: tuple[np.ndarray, ...], output: Path) -> None:
    w1, b1, w2, b2 = weights
    builder = NeuralNetworkBuilder(
        [("features", datatypes.Array(FEATURE_COUNT))],
        [("scores", datatypes.Array(len(CLASSES)))],
        disable_rank5_shape_mapping=True,
    )
    # Core ML stores inner-product weights as [output_channels, input_channels],
    # while the NumPy trainer uses [input_channels, output_channels].
    builder.add_inner_product("hidden", w1.T, b1, FEATURE_COUNT, HIDDEN_COUNT, True, "features", "hidden_pre")
    builder.add_activation("relu", "RELU", "hidden_pre", "hidden")
    builder.add_inner_product("scores", w2.T, b2, HIDDEN_COUNT, len(CLASSES), True, "hidden", "scores")
    builder.spec.description.metadata.shortDescription = "Cappy tiny contextual edit reranker"
    builder.spec.description.metadata.author = "Cappy"
    builder.spec.description.metadata.license = "Model weights generated from synthetic templates in this repository"
    output.parent.mkdir(parents=True, exist_ok=True)
    ct.models.MLModel(builder.spec).save(str(output))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("Resources/ContextReranker.mlmodel"))
    parser.add_argument("--metrics", type=Path, default=Path("ML/metrics.json"))
    args = parser.parse_args()
    train_rows, test_rows = examples()
    train_x, train_y = matrix(train_rows)
    test_x, test_y = matrix(test_rows)
    start = time.perf_counter()
    weights = train(train_x, train_y)
    elapsed = time.perf_counter() - start
    test_probabilities = probabilities(test_x, weights)
    predictions = test_probabilities.argmax(axis=1)
    confidence = test_probabilities.max(axis=1)
    accuracy = float((predictions == test_y).mean())
    high_confidence = confidence >= AUTOMATIC_THRESHOLD
    high_confidence_precision = float((predictions[high_confidence] == test_y[high_confidence]).mean()) if high_confidence.any() else 0.0
    high_confidence_coverage = float(high_confidence.mean())
    export_model(weights, args.output)
    metrics = {
        "classes": CLASSES,
        "feature_count": FEATURE_COUNT,
        "hidden_count": HIDDEN_COUNT,
        "parameter_count": int(sum(array.size for array in weights)),
        "training_examples": len(train_rows),
        "test_examples": len(test_rows),
        "test_accuracy": accuracy,
        "high_confidence_threshold": AUTOMATIC_THRESHOLD,
        "high_confidence_precision": high_confidence_precision,
        "high_confidence_coverage": high_confidence_coverage,
        "training_seconds": elapsed,
    }
    args.metrics.parent.mkdir(parents=True, exist_ok=True)
    args.metrics.write_text(json.dumps(metrics, indent=2) + "\n")
    print(json.dumps(metrics, indent=2))


if __name__ == "__main__":
    main()
