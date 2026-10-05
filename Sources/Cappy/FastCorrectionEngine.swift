import Foundation

struct FastCorrection: Equatable {
    let original: String
    let replacement: String
    let suffix: String

    var originalUTF16Length: Int { (original as NSString).length }
    var replacementUTF16Length: Int { (replacement as NSString).length }
    var suffixUTF16Length: Int { (suffix as NSString).length }
}

enum CorrectionRangePlanner {
    static func sourceRange(for correction: FastCorrection, selection: NSRange) -> NSRange? {
        let consumedLength = correction.originalUTF16Length + correction.suffixUTF16Length
        guard selection.location != NSNotFound,
              selection.length == 0,
              selection.location >= consumedLength else { return nil }
        return NSRange(
            location: selection.location - consumedLength,
            length: correction.originalUTF16Length
        )
    }

    static func undoRange(for correction: FastCorrection, sourceRange: NSRange) -> NSRange {
        NSRange(
            location: sourceRange.location,
            length: correction.replacementUTF16Length + correction.suffixUTF16Length
        )
    }
}

/// A bounded, deterministic correction engine for high-confidence edits. It
/// retains only the active word and enough state to recognise sentence starts.
struct FastCorrectionEngine {
    typealias CandidateProvider = (String) -> [String]
    typealias SuppressionProvider = (_ original: String, _ replacement: String) -> Bool
    typealias ContextualSpellingProvider = (_ history: [String], _ current: String) -> (original: String, replacement: String)?
    typealias RerankProvider = (_ tokens: [String]) -> ContextualRerankDecision?

    static let maximumWordLength = 32
    static let maximumContextUTF16Length = 96

    private(set) var currentWord = ""
    private(set) var generation: UInt64 = 0
    private var pendingPunctuation = ""
    private var tokenIsProtected = false
    private var wordOverflowed = false
    private var wordBeganSentence = false
    private var nextWordBeginsSentence = true
    private let candidateProvider: CandidateProvider
    private let suppressionProvider: SuppressionProvider
    private let rerankProvider: RerankProvider?
    private let contextualSpellingProvider: ContextualSpellingProvider?
    private var recentWords: [String] = []
    private let phraseProvider: (([String]) -> [CorrectionCandidate])?
    private let personalScore: (CorrectionCandidate) -> Double
    private let observationProvider: (String) -> Void
    private(set) var suggestion: FastCorrection?
    private(set) var lastCandidate: CorrectionCandidate?


    init(
        candidateProvider: @escaping CandidateProvider = NativeSpellingCandidates.suggestions,
        suppressionProvider: @escaping SuppressionProvider = { _, _ in false },
        rerankProvider: RerankProvider? = nil,
        contextualSpellingProvider: ContextualSpellingProvider? = nil,
        phraseProvider: (([String]) -> [CorrectionCandidate])? = nil,
        personalScore: @escaping (CorrectionCandidate) -> Double = { _ in 0 },
        observationProvider: @escaping (String) -> Void = { _ in }

    ) {
        self.candidateProvider = candidateProvider
        self.suppressionProvider = suppressionProvider
        self.rerankProvider = rerankProvider
        self.contextualSpellingProvider = contextualSpellingProvider
        self.phraseProvider = phraseProvider
        self.personalScore = personalScore
        self.observationProvider = observationProvider
    }

    mutating func locateCandidate(in range: NSRange) { lastCandidate?.sourceRange = range }

    mutating func invalidate() {
        currentWord.removeAll(keepingCapacity: true)
        pendingPunctuation = ""
        tokenIsProtected = false
        wordOverflowed = false
        wordBeganSentence = false
        nextWordBeginsSentence = true
        recentWords.removeAll(keepingCapacity: true)
        suggestion = nil; lastCandidate = nil
        generation &+= 1
    }

    mutating func synchronize(leftContext: String?) {
        currentWord.removeAll(keepingCapacity: true)
        pendingPunctuation = ""
        tokenIsProtected = false
        wordOverflowed = false
        wordBeganSentence = false
        recentWords.removeAll(keepingCapacity: true)

        guard let leftContext else {
            nextWordBeginsSentence = false
            return
        }

        nextWordBeginsSentence = true
        _ = consume(leftContext, allowsCorrection: false)
    }

    mutating func consume(_ text: String) -> FastCorrection? {
        consume(text, allowsCorrection: true)
    }

    private mutating func consume(_ text: String, allowsCorrection: Bool) -> FastCorrection? {
        var correction: FastCorrection?
        if allowsCorrection { suggestion = nil; lastCandidate = nil }

        for character in text {
            if Self.isWordLetter(character)
                || (Self.isApostrophe(character) && !currentWord.isEmpty && currentWord.last.map(Self.isWordLetter) == true) {
                if !pendingPunctuation.isEmpty {
                    // A letter after punctuation is part of a domain/identifier.
                    tokenIsProtected = true
                    pendingPunctuation = ""
                }
                if currentWord.isEmpty {
                    wordBeganSentence = nextWordBeginsSentence
                }
                if !wordOverflowed { currentWord.append(character) }
                if currentWord.count > Self.maximumWordLength {
                    currentWord.removeAll(keepingCapacity: true)
                    wordOverflowed = true
                }
                continue
            }

            if ".,!?;:".contains(character), !currentWord.isEmpty,
               !tokenIsProtected, !wordOverflowed, pendingPunctuation.count < 4 {
                // Wait for a boundary before correcting: "whta? " is prose,
                // while "whta.com" must remain an untouched domain.
                pendingPunctuation.append(character)
                continue
            }

            let completedWord = currentWord
            if character.isWhitespace,
               !tokenIsProtected,
               !wordOverflowed,
               allowsCorrection,
               let candidate = bestCandidate(for: completedWord, atSentenceStart: wordBeganSentence) {
                lastCandidate = candidate
                let replacement = (original: candidate.source, replacement: candidate.replacement)
                let decision = FastCorrection(original: replacement.original, replacement: replacement.replacement,
                    suffix: pendingPunctuation + String(character))
                if candidate.tier == .automatic { correction = decision }
                else if candidate.tier == .suggestion { suggestion = decision }
            }

            if !completedWord.isEmpty {
                if allowsCorrection && correction == nil && !tokenIsProtected && !wordOverflowed { observationProvider(completedWord) }
                nextWordBeginsSentence = false
                remember(
                    correction?.replacement ?? completedWord,
                    replacingPreviousWordCount: max(
                        0,
                        (correction?.original.split(whereSeparator: { $0.isWhitespace }).count ?? 1) - 1
                    )
                )
            }
            if Self.endsSentence(character) || pendingPunctuation.contains(where: Self.endsSentence) {
                nextWordBeginsSentence = true
                recentWords.removeAll(keepingCapacity: true)
            }
            // Phrase spans must never cross non-space separators, punctuation or protected tokens.
            if character != " " || !pendingPunctuation.isEmpty || tokenIsProtected || wordOverflowed { recentWords.removeAll(keepingCapacity: true) }
            currentWord.removeAll(keepingCapacity: true)
            pendingPunctuation = ""
            wordBeganSentence = false
            if character.isWhitespace {
                tokenIsProtected = false
                wordOverflowed = false
            } else {
                tokenIsProtected = true
            }
        }

        return correction
    }

    private func bestCandidate(for word: String, atSentenceStart: Bool) -> CorrectionCandidate? {
        guard !word.isEmpty else { return nil }
        var candidates: [CorrectionCandidate] = []
        func add(_ source: String, _ replacement: String, _ confidence: Double, _ type: String, _ evidence: String) {
            guard source != replacement else { return }
            candidates.append(CorrectionCandidate(source: source, replacement: replacement, type: type,
                baseConfidence: confidence, contextualConfidence: 0, evidence: evidence))
        }
        if let replacement = replacement(for: word, atSentenceStart: atSentenceStart) {
            let lhs = word.lowercased(), rhs = replacement.lowercased()
            let apostropheOnly = rhs.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "") == lhs
            let transposition = lhs.sorted() == rhs.sorted() && Self.editDistance(lhs, rhs) == 1
            let repeatedLetter = lhs.count == rhs.count + 1 && zip(lhs, lhs.dropFirst()).contains { $0 == $1 }
            let caseOnly = lhs == rhs
            let distance = Self.editDistance(lhs, rhs)
            let competing = candidateProvider(lhs).prefix(8).filter {
                $0.lowercased() != rhs && !$0.contains(" ") && $0.count <= Self.maximumWordLength
                    && Self.editDistance(lhs, $0.lowercased()) <= distance
            }.count
            let confidence = caseOnly || apostropheOnly ? 0.995
                : transposition || repeatedLetter || replacement.contains(" ") ? 0.99
                : word.count >= 5 && distance == 1 && competing == 0 ? 0.985
                : distance <= 1 && competing <= 2 && word.count >= 4 && !(word.count == 4 && rhs.count < lhs.count) ? 0.86 : 0.70
            add(word, replacement, confidence, caseOnly ? "case" : "spelling", "native dictionary and bounded edit evidence")
        }
        if Self.hasSimpleCasing(word) {
            for alternative in candidateProvider(word.lowercased()).prefix(4).dropFirst() {
                guard alternative.count <= 32 else { continue }
                let lower = alternative.lowercased()
                guard Self.editDistance(word.lowercased(), lower) <= 1 || Self.highConfidenceMissingSpace(from: word.lowercased(), candidate: lower) != nil else { continue }
                let replacement = word.first?.isUppercase == true ? Self.capitalizingFirstLetter(of: lower) : lower
                add(word, replacement, 0.70, "spelling-alternative", "nearby native alternative; requires contextual or personal evidence")
            }
        }
        if let contextual = ContextualScorer.replacement(history: recentWords, current: word) {
            add(contextual.original, contextual.replacement, 0.985, "context", "validated constrained grammar pattern")
        }
        if let contextual = contextualSpellingProvider?(recentWords, word) {
            add(contextual.original, contextual.replacement, 0.985, "frequency", "two-sided corpus transposition evidence")
        }
        if let neural = neuralReplacement(for: word) {
            add(neural.original, neural.replacement, neural.confidence, "coreml", "local constrained classifier")
        }
        candidates += phraseProvider?(Array(recentWords.suffix(3)) + [word]) ?? []
        for index in candidates.indices {
            let spanWords = candidates[index].source.split(separator: " ").count
            candidates[index].contextSignature = PersonalizationStore.contextSignature(Array(recentWords.dropLast(max(0, spanWords - 1))))
            candidates[index].personalisationAdjustment = personalScore(candidates[index])
        }
        return candidates.filter {
            !suppressionProvider($0.source, $0.replacement) && $0.tier != .ignore
        }.sorted {
            // All stages compete by confidence, rather than by execution order.
            let lhs = $0.finalConfidence
            let rhs = $1.finalConfidence
            return lhs == rhs ? $0.source < $1.source : lhs > rhs
        }.first
    }

    private func neuralReplacement(for word: String) -> (original: String, replacement: String, confidence: Double)? {
        guard (Array(recentWords.suffix(4)) + [word]).contains(where: { ["your", "their", "there", "its", "of"].contains($0.lowercased()) }),
              let rerankProvider,
              let decision = rerankProvider(Array(recentWords.suffix(4)) + [word]),
              decision.confidence >= CorrectionConfidence.automatic,
              decision.action != .keep else { return nil }

        func preserveCase(_ source: String, _ replacement: String) -> String {
            guard source.first?.isUppercase == true, let first = replacement.first else { return replacement }
            return first.uppercased() + replacement.dropFirst()
        }

        if decision.action == .thereToTheir,
           let previous = recentWords.last,
           previous.lowercased() == "there" {
            return (previous + " " + word, preserveCase(previous, "their") + " " + word, decision.confidence)
        }
        if decision.action == .ofToHave,
           let previous = recentWords.last,
           ["should", "could", "would"].contains(previous.lowercased()),
           word.lowercased() == "of" {
            return (previous + " " + word, previous + " have", decision.confidence)
        }

        guard recentWords.count >= 2 else { return nil }
        let subject = recentWords[recentWords.count - 2]
        let predicate = recentWords[recentWords.count - 1]
        let expectedSubject: String
        let contraction: String
        switch decision.action {
        case .yourToYoure: expectedSubject = "your"; contraction = "you're"
        case .theirToTheyre: expectedSubject = "their"; contraction = "they're"
        case .thereToTheyre: expectedSubject = "there"; contraction = "they're"
        case .itsToItsApostrophe: expectedSubject = "its"; contraction = "it's"
        default: return nil
        }
        guard subject.lowercased() == expectedSubject else { return nil }
        let original = [subject, predicate, word].joined(separator: " ")
        let replacement = [preserveCase(subject, contraction), predicate, word].joined(separator: " ")
        return (original, replacement, decision.confidence)
    }

    private mutating func remember(_ correctedText: String, replacingPreviousWordCount: Int) {
        let words = correctedText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if replacingPreviousWordCount > 0 {
            recentWords.removeLast(min(replacingPreviousWordCount, recentWords.count))
        }
        recentWords.append(contentsOf: words)
        if recentWords.count > 12 {
            recentWords.removeFirst(recentWords.count - 12)
        }
    }

    private func replacement(for word: String, atSentenceStart: Bool) -> String? {
        guard !word.isEmpty, Self.hasSimpleCasing(word) else { return nil }
        let lowercased = word.lowercased()
        var replacement: String? = lowercased == "i" ? "I" : nil

        if replacement == nil, Self.hasSimpleCasing(word) {
            replacement = dictionaryReplacement(for: lowercased)
        }

        if replacement == nil, atSentenceStart, word.first?.isLowercase == true {
            replacement = Self.capitalizingFirstLetter(of: word)
        }
        guard var replacement, replacement != word else { return nil }

        if atSentenceStart {
            replacement = Self.capitalizingFirstLetter(of: replacement)
        } else if word.first?.isUppercase == true {
            replacement = Self.capitalizingFirstLetter(of: replacement)
        }
        return replacement == word ? nil : replacement
    }

    private func dictionaryReplacement(for word: String) -> String? {
        guard word.count >= 2,
              word.unicodeScalars.allSatisfy({
                  CharacterSet.lowercaseLetters.contains($0) || $0 == "'" || $0 == "’"
              }) else { return nil }

        let suggestions = candidateProvider(word).prefix(8)
        guard let first = suggestions.first else { return nil }
        if let split = Self.highConfidenceMissingSpace(from: word, candidate: first) {
            return split
        }
        // Use the dictionary's recommendation for any nearby spelling error,
        // rather than requiring the typo to belong to a reviewed lookup table.
        guard first.allSatisfy({ Self.isWordLetter($0) || Self.isApostrophe($0) }),
              first.count <= Self.maximumWordLength,
              Self.editDistance(word, first.lowercased()) <= (word.count >= 5 ? 2 : 1) else { return nil }
        return first
    }

    /// Damerau-Levenshtein distance includes swapped adjacent letters.
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let source = Array(lhs), target = Array(rhs)
        var matrix = Array(repeating: Array(repeating: 0, count: target.count + 1), count: source.count + 1)
        for index in 0...source.count { matrix[index][0] = index }
        for index in 0...target.count { matrix[0][index] = index }
        guard !source.isEmpty, !target.isEmpty else { return max(source.count, target.count) }
        for row in 1...source.count {
            for column in 1...target.count {
                matrix[row][column] = min(
                    matrix[row - 1][column] + 1,
                    matrix[row][column - 1] + 1,
                    matrix[row - 1][column - 1] + (source[row - 1] == target[column - 1] ? 0 : 1)
                )
                if row > 1, column > 1,
                   source[row - 1] == target[column - 2], source[row - 2] == target[column - 1] {
                    matrix[row][column] = min(matrix[row][column], matrix[row - 2][column - 2] + 1)
                }
            }
        }
        return matrix[source.count][target.count]
    }

    private static func highConfidenceMissingSpace(from observed: String, candidate: String) -> String? {
        let parts = candidate.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2,
              parts.allSatisfy({ $0.count >= 2 }),
              candidate.allSatisfy({ isWordLetter($0) || isApostrophe($0) || $0 == " " }) else { return nil }

        func normalized(_ value: String) -> String {
            value.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: " ", with: "")
        }
        guard normalized(candidate) == normalized(observed) else { return nil }
        return parts.joined(separator: " ")
    }

    private static func capitalizingFirstLetter(of text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func hasSimpleCasing(_ word: String) -> Bool {
        word == word.lowercased() || capitalizingFirstLetter(of: word.lowercased()) == word
    }

    private static func endsSentence(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?" || character == "\n"
    }

    private static func isWordLetter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.letters.contains)
    }

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "’"
    }
}

enum ContextualScorer {
    private static let predicateWords: Set<String> = [
        "amazing", "coming", "doing", "early", "going", "great", "late", "leaving",
        "right", "ready", "sure", "welcome", "wrong"
    ]
    private static let possessionWords: Set<String> = [
        "bag", "car", "choice", "computer", "friend", "home", "house", "idea", "name",
        "phone", "problem", "room", "team", "work"
    ]
    private static let predicateComplements: Set<String> = [
        "again", "away", "back", "great", "here", "home", "now", "out", "soon", "there", "to"
    ]

    static func replacement(history: [String], current: String) -> (original: String, replacement: String)? {
        guard let previous = history.last else { return nil }
        let lhs = previous.lowercased()
        let rhs = current.lowercased()

        if ["should", "could", "would"].contains(lhs), rhs == "of" {
            return (previous + " " + current, preserveInitialCase(of: previous, in: lhs + " have"))
        }
        if lhs == "there", possessionWords.contains(rhs) {
            return (previous + " " + current, preserveInitialCase(of: previous, in: "their " + current))
        }

        guard history.count >= 2 else { return nil }
        let subject = history[history.count - 2]
        let predicate = previous
        let subjectLower = subject.lowercased()
        let predicateLower = predicate.lowercased()
        guard predicateWords.contains(predicateLower), predicateComplements.contains(rhs) else { return nil }

        let contraction: String
        switch subjectLower {
        case "your": contraction = "you're"
        case "their", "there": contraction = "they're"
        case "its": contraction = "it's"
        default: return nil
        }
        let original = [subject, predicate, current].joined(separator: " ")
        let replacement = [preserveInitialCase(of: subject, in: contraction), predicate, current].joined(separator: " ")
        return (original, replacement)
    }

    private static func preserveInitialCase(of original: String, in replacement: String) -> String {
        guard original.first?.isUppercase == true, let first = replacement.first else { return replacement }
        return first.uppercased() + replacement.dropFirst()
    }
}
