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
    /// Upper bound set by the homophone guard; it never raises a confidence.
    var confidenceCeiling: Double = 0.9995
    var finalConfidence: Double { min(confidenceCeiling, max(0, baseConfidence + contextualConfidence + personalisationAdjustment)) }
    var tier: CorrectionTier { CorrectionConfidence.tier(finalConfidence) }
    var eligibleForAutomaticCorrection: Bool { tier == .automatic }
    var suggestionOnly: Bool { tier == .suggestion }
}

enum HomophoneEvidence: Equatable { case supports, unclear, contradicts }

/// Swapping one valid homophone for another always yields a real word, so a
/// classifier's confidence alone cannot justify the edit: “when there is one”
/// must never become “when their is one”. Such a swap is automatic only when
/// the exact context corroborates it; otherwise it is at most a suggestion.
enum HomophoneGuard {
    static let groups: [Set<String>] = [
        ["there", "their", "they're"], ["your", "you're"], ["its", "it's"], ["to", "too", "two"], ["then", "than"]
    ]
    /// The highest confidence an uncorroborated homophone swap may keep.
    static let suggestionCeiling = 0.97

    private static func normalized(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    /// The word positions where `source` → `replacement` swaps homophones, or
    /// nil when anything else changes (a typo fix is not a homophone swap).
    static func swappedIndices(source: [String], replacement: [String]) -> [Int]? {
        guard source.count == replacement.count else { return nil }
        var indices: [Int] = []
        for (index, (lhs, rhs)) in zip(source, replacement).enumerated() {
            let lhs = normalized(lhs), rhs = normalized(rhs)
            guard lhs != rhs else { continue }
            guard groups.contains(where: { $0.contains(lhs) && $0.contains(rhs) }) else { return nil }
            indices.append(index)
        }
        return indices.isEmpty ? nil : indices
    }

    private static let existentialInversions: Set<String> = [
        "is", "was", "are", "were", "isn't", "wasn't", "aren't", "weren't"
    ]
    private static let questionOpeners: Set<String> = [
        "what", "why", "where", "when", "how", "who", "which", "so", "and", "but", "or", "then", "now"
    ]

    /// “Is there room?” and “why was there going to be food?” ask whether
    /// something exists: “there” right after a verb that opens the clause is
    /// never possessive. “That is there phone” has a subject first, so it
    /// is left to the other evidence. `before` holds the words before `source`.
    static func isExistentialQuestion(before: [String], source: [String], replacement: [String]) -> Bool {
        guard let changed = swappedIndices(source: source, replacement: replacement) else { return false }
        let words = (before + source).map(normalized)
        return changed.contains { index in
            let position = index + before.count
            guard words[position] == "there", position > 0, existentialInversions.contains(words[position - 1]) else { return false }
            return position == 1 || questionOpeners.contains(words[position - 2])
        }
    }

    /// Two-sided corpus comparison of the swap with the words around it. A
    /// form the corpus cannot score, such as a contraction, is unclear.
    static func evidence(left: String?, source: [String], replacement: [String], frequencies: WordFrequencyModel) -> HomophoneEvidence {
        guard frequencies.isAvailable,
              let changed = swappedIndices(source: source, replacement: replacement) else { return .unclear }
        let original = ([left].compactMap { $0 } + source).map(normalized)
        let proposed = ([left].compactMap { $0 } + replacement).map(normalized)
        let offset = left == nil ? 0 : 1
        var gain = 0.0, originalAttested = true, proposedAttested = true
        for index in changed.map({ $0 + offset }) {
            guard frequencies.count(original[index]) != nil, frequencies.count(proposed[index]) != nil else { return .unclear }
            for (lhs, rhs) in [(index - 1, index), (index, index + 1)] where lhs >= 0 && rhs < original.count {
                func logProbability(_ words: [String]) -> Double? {
                    guard let base = frequencies.count(words[lhs]) else { return nil }
                    return (frequencies.count(words[lhs] + " " + words[rhs]) ?? log(100.0)) - base
                }
                guard let before = logProbability(original), let after = logProbability(proposed) else { return .unclear }
                originalAttested = originalAttested && frequencies.count(original[lhs] + " " + original[rhs]) != nil
                proposedAttested = proposedAttested && frequencies.count(proposed[lhs] + " " + proposed[rhs]) != nil
                gain += after - before
            }
        }
        if gain >= log(20.0) && proposedAttested { return .supports }
        if gain <= 0 && originalAttested { return .contradicts }
        return .unclear
    }
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

struct RankedSpelling: Equatable {
    let replacement: String
    let confidence: Double
}

/// Chooses among dictionary guesses for a flagged word using corpus frequency,
/// the neighbouring words and common typing slips. It decides only when one
/// guess clearly wins; anything closer is left to the other stages.
struct SpellingRanker {
    let frequencies: WordFrequencyModel
    /// Cached dictionary guesses only; ranking never waits on the spell checker.
    let provider: (String) -> [String]
    /// Stupid-backoff weight for a missing word pair.
    private static let backoff = log(0.4)

    func rank(previous: String?, word: String, next: String?) -> RankedSpelling? {
        let source = word.lowercased()
        guard frequencies.isAvailable, source.count >= 3, source.count <= FastCorrectionEngine.maximumWordLength,
              source.allSatisfy(\.isLetter) else { return nil }
        let guesses = provider(source)
        guard !guesses.isEmpty else { return nil }
        // A common word stays: its own corpus evidence outweighs a guess.
        let sourceCount = frequencies.count(source) ?? 0
        let maximumDistance = source.count <= 4 ? 1 : source.count <= 7 ? 2 : 3
        var options: [(word: String, distance: Int, count: Double)] = []
        for guess in guesses.prefix(8) where guess == guess.lowercased() {
            guard guess != source, guess.allSatisfy(\.isLetter), !options.contains(where: { $0.word == guess }),
                  let count = frequencies.count(guess), count - sourceCount >= log(50.0) else { continue }
            let distance = FastCorrectionEngine.editDistance(source, guess)
            guard distance <= maximumDistance else { continue }
            options.append((guess, distance, count))
        }
        guard !options.isEmpty else { return nil }

        let total = (frequencies.count("the") ?? 23) + log(25.0)
        let left = previous?.lowercased(), right = next?.lowercased()
        var supported = Set<String>()
        func score(_ option: (word: String, distance: Int, count: Double)) -> Double {
            // log P(option | previous) + log P(next | option) + a small error model.
            var value: Double
            if let left, let pair = frequencies.count(left + " " + option.word), let base = frequencies.count(left) {
                value = pair - base
                supported.insert(option.word)
            } else {
                value = option.count - total + (left == nil ? 0 : Self.backoff)
            }
            if let right {
                if let pair = frequencies.count(option.word + " " + right) {
                    value += pair - option.count
                    supported.insert(option.word)
                } else {
                    value += (frequencies.count(right) ?? log(100_000.0)) - total + Self.backoff
                }
            }
            value -= Double(option.distance - 1) * 2.5
            if Self.isCommonSlip(source, option.word) { value += 1.2 }
            if option.word == guesses.first { value += 0.7 }
            return value
        }
        typealias Option = (word: String, distance: Int, count: Double)
        var ranked: [(option: Option, score: Double)] = options.map { (option: $0, score: score($0)) }
        ranked.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.option.word < rhs.option.word : lhs.score > rhs.score
        }
        let best = ranked[0]
        let margin = ranked.count > 1 ? best.score - ranked[1].score : .infinity
        let hasContext = supported.contains(best.option.word)
        // Short words are too ambiguous for frequency alone, and distant
        // guesses must be the only plausible word.
        guard margin >= (hasContext ? 2.3 : 3.0),
              hasContext || source.count >= 5,
              best.option.distance <= 2 || (source.count >= 8 && ranked.count == 1) else { return nil }
        return RankedSpelling(replacement: best.option.word, confidence: 0.985)
    }

    /// Typing slips far likelier than an arbitrary edit: a dropped or repeated
    /// double letter, swapped neighbours, or a neighbouring key.
    static func isCommonSlip(_ typed: String, _ intended: String) -> Bool {
        let lhs = Array(typed), rhs = Array(intended)
        if rhs.count == lhs.count + 1 {
            for index in 1..<rhs.count where rhs[index] == rhs[index - 1] {
                var shortened = rhs; shortened.remove(at: index)
                if shortened == lhs { return true }
            }
        }
        if lhs.count == rhs.count + 1 {
            for index in 1..<lhs.count where lhs[index] == lhs[index - 1] {
                var shortened = lhs; shortened.remove(at: index)
                if shortened == rhs { return true }
            }
        }
        guard lhs.count == rhs.count else { return false }
        let differences = zip(lhs, rhs).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        if differences.count == 2, differences[1] == differences[0] + 1,
           lhs[differences[0]] == rhs[differences[1]], lhs[differences[1]] == rhs[differences[0]] { return true }
        if differences.count == 1, let neighbours = keyboardNeighbours[rhs[differences[0]]] {
            return neighbours.contains(lhs[differences[0]])
        }
        return false
    }

    private static let keyboardNeighbours: [Character: Set<Character>] = {
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map(Array.init)
        var result: [Character: Set<Character>] = [:]
        for (row, keys) in rows.enumerated() {
            for (column, key) in keys.enumerated() {
                var near = Set<Character>()
                for (otherRow, otherKeys) in rows.enumerated() where abs(otherRow - row) <= 1 {
                    for (otherColumn, other) in otherKeys.enumerated() where other != key {
                        // Lower rows are staggered half a key to the right.
                        let offset = Double(otherColumn - column) + Double(otherRow - row) * 0.5
                        if abs(offset) <= 1 { near.insert(other) }
                    }
                }
                result[key] = near
            }
        }
        return result
    }()
}
