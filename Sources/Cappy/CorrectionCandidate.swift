import Foundation

enum CorrectionTier: String { case automatic, suggestion, ignore }
struct CorrectionConfidence {
    static let automatic = 0.98
    static let suggestion = 0.75
    static func tier(_ value: Double) -> CorrectionTier {
        value >= automatic ? .automatic : value >= suggestion ? .suggestion : .ignore
    }
}

struct CorrectionCandidate: Equatable {
    let source: String
    let replacement: String
    /// Absolute UTF-16 document range, populated only after source validation.
    var sourceRange: NSRange? = nil
    let type: String
    let baseConfidence: Double
    let contextualConfidence: Double
    var personalisationAdjustment: Double = 0
    let evidence: String
    var contextSignature: String = ""
    var finalConfidence: Double { min(0.9995, max(0, baseConfidence + contextualConfidence + personalisationAdjustment)) }
    var tier: CorrectionTier { CorrectionConfidence.tier(finalConfidence) }
    var eligibleForAutomaticCorrection: Bool { tier == .automatic }
    var suggestionOnly: Bool { tier == .suggestion }
}

/// Bounded phrase search: four words, four alternatives per word, twelve beams.
/// Candidates come from native spelling/edit neighbours and boundary relocation,
/// not a table of example phrases. Corpus likelihood and runner-up margin prune
/// weak real-word edits. Unknown pairs are weak evidence, never a grammar verdict.
struct ContextualPhraseRanker {
    let frequencies: WordFrequencyModel
    let provider: (String) -> [String]
    private struct Beam { var words: [String]; var edits: Int; var score: Double }

    func candidates(tokens: [String]) -> [CorrectionCandidate] {
        let original = Array(tokens.suffix(4))
        guard original.count >= 2, frequencies.isAvailable,
              original.allSatisfy({ Self.simple($0) && $0.count <= 24 }) else { return [] }
        let lower = original.map { $0.lowercased() }
        func safeChange(_ source: String, _ target: String) -> Bool {
            source == target || source.sorted() == target.sorted() || frequencies.count(source) == nil
                || ((source.count <= 3 || (source.count == 4 && target.count == 3 && source.hasSuffix(target)) || (source.count <= 5 && target.count == source.count + 1 && (frequencies.count(source) ?? 0) < log(1_000_000.0))) && (frequencies.count(source) ?? 0) < log(50_000_000.0)
                    && (frequencies.count(target) ?? 0) - (frequencies.count(source) ?? 0) >= log(8.0))
        }
        var beams = [Beam(words: [], edits: 0, score: 0)]
        for word in lower {
            let nearby = provider(word).prefix(8).map { $0.lowercased().replacingOccurrences(of: "’", with: "'") }
            let options = [word] + Array(Set(nearby + frequencies.shortNeighbours(word)).filter {
                $0 != word && !$0.contains(" ") && $0.count >= 2 && $0.count <= 24 && frequencies.count($0) != nil
                    && FastCorrectionEngine.editDistance(word, $0) <= 1 && safeChange(word, $0)
            }.sorted {
                let lhs = frequencies.count($0) ?? 0, rhs = frequencies.count($1) ?? 0
                return lhs == rhs ? $0 < $1 : lhs > rhs
            }.prefix(3))
            var next: [Beam] = []
            for beam in beams {
                for option in options {
                    let edits = beam.edits + (option == word ? 0 : 1)
                    guard edits <= 2 else { continue }
                    let words = beam.words + [option]
                    next.append(Beam(words: words, edits: edits, score: score(words) - Double(edits) * 1.6))
                }
            }
            beams = Array(next.sorted { $0.score == $1.score ? $0.words.joined() < $1.words.joined() : $0.score > $1.score }.prefix(12))
        }
        // Moving a space repairs neighbouring word boundaries without adding letters.
        for index in 0..<(lower.count - 1) {
            let joined = lower[index] + lower[index + 1]
            for offset in [lower[index].count - 1, lower[index].count + 1] where offset > 0 && offset < joined.count {
                let lhs = String(joined.prefix(offset)), rhs = String(joined.dropFirst(offset))
                guard frequencies.count(lhs) != nil || frequencies.count(rhs) != nil else { continue }
                var words = lower; words[index] = lhs; words[index + 1] = rhs
                if frequencies.count(lhs) != nil && frequencies.count(rhs) != nil {
                    beams.append(Beam(words: words, edits: 1, score: score(words) - 1.6))
                }
                // A relocated boundary may leave one half transposed. Repair only
                // that half, with two corpus neighbours and no cross product.
                for side in [index, index + 1] {
                    for neighbour in frequencies.shortNeighbours(words[side]).prefix(2) where neighbour.sorted() == words[side].sorted() {
                        var repaired = words; repaired[side] = neighbour
                        guard repaired.allSatisfy({ frequencies.count($0) != nil }) else { continue }
                        beams.append(Beam(words: repaired, edits: 2, score: score(repaired) - 3.2))
                    }
                }
            }
        }
        let baseline = score(lower)
        var unique: [String: Beam] = [:]
        for beam in beams where beam.words != lower {
            let key = beam.words.joined(separator: " ")
            if unique[key] == nil || beam.score > unique[key]!.score { unique[key] = beam }
        }
        let ranked = unique.values.sorted { $0.score == $1.score ? $0.words.joined() < $1.words.joined() : $0.score > $1.score }
        guard let best = ranked.first else { return [] }
        let gain = best.score - baseline
        let margin = best.score - max(baseline, ranked.dropFirst().first?.score ?? baseline)
        let supported = zip(best.words, best.words.dropFirst()).filter {
            (frequencies.count($0 + " " + $1) ?? 0) >= log(50_000.0)
        }.count
        guard gain >= 5, margin >= (best.edits >= 2 ? 1.5 : 0.6), supported >= 1 else { return [] }
        // Real-word changes require two observed supporting edges for automatic use.
        let boundaryMoved = lower.joined() == best.words.joined() || (lower.joined().sorted() == best.words.joined().sorted() && FastCorrectionEngine.editDistance(lower.joined(), best.words.joined()) == 1)
        let changes = zip(lower, best.words).filter { $0 != $1 }
        let safeChanges = changes.allSatisfy { source, target in
            let transposition = source.sorted() == target.sorted()
            let rareShort = (source.count <= 3 || (source.count == 4 && target.count == 3 && source.hasSuffix(target))) && (frequencies.count(source) ?? 0) < log(50_000_000.0)
                && (frequencies.count(target) ?? 0) - (frequencies.count(source) ?? 0) >= log(8.0)
            return transposition || rareShort || frequencies.count(source) == nil
        }
        // Preserve specialised casing and rare ordinary words: two-sided corpus
        // likelihood by itself cannot justify arbitrary real-word substitution.
        guard boundaryMoved || safeChanges else { return [] }
        let automatic = gain >= 7 && margin >= 1.5 && supported >= 2 && (boundaryMoved || safeChanges)
        let confidence = automatic ? 0.985 : min(0.96, 0.78 + gain * 0.012)
        let replacement = zip(original, best.words).map { source, target in
            source.first?.isUppercase == true ? target.prefix(1).uppercased() + target.dropFirst() : target
        }.joined(separator: " ")
        return [CorrectionCandidate(source: original.joined(separator: " "), replacement: replacement,
            type: "phrase", baseConfidence: 0.75, contextualConfidence: confidence - 0.75,
            evidence: "bounded corpus beam; gain=\(gain); margin=\(margin); supported=\(supported)")]
    }

    func score(_ words: [String]) -> Double {
        guard let first = words.first else { return 0 }
        var value = (frequencies.count(first) ?? log(100.0)) * 0.15
        for (left, right) in zip(words, words.dropFirst()) {
            value += (frequencies.count(left + " " + right) ?? log(100.0)) - (frequencies.count(left) ?? log(100.0))
        }
        return value
    }
    static func simple(_ word: String) -> Bool {
        let lower = word.lowercased()
        return (word == lower || word == lower.prefix(1).uppercased() + lower.dropFirst())
            && word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" }
    }
}
