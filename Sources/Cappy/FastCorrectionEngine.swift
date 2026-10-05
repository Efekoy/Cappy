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

    init(
        candidateProvider: @escaping CandidateProvider = NativeSpellingCandidates.suggestions,
        suppressionProvider: @escaping SuppressionProvider = { _, _ in false },
        rerankProvider: RerankProvider? = nil,
        contextualSpellingProvider: ContextualSpellingProvider? = nil
    ) {
        self.candidateProvider = candidateProvider
        self.suppressionProvider = suppressionProvider
        self.rerankProvider = rerankProvider
        self.contextualSpellingProvider = contextualSpellingProvider
    }

    mutating func invalidate() {
        currentWord.removeAll(keepingCapacity: true)
        pendingPunctuation = ""
        tokenIsProtected = false
        wordOverflowed = false
        wordBeganSentence = false
        nextWordBeginsSentence = true
        recentWords.removeAll(keepingCapacity: true)
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
               let replacement = bestReplacement(for: completedWord, atSentenceStart: wordBeganSentence) {
                correction = FastCorrection(
                    original: replacement.original,
                    replacement: replacement.replacement,
                    suffix: pendingPunctuation + String(character)
                )
            }

            if !completedWord.isEmpty {
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

    private func bestReplacement(for word: String, atSentenceStart: Bool) -> (original: String, replacement: String)? {
        if let replacement = replacement(for: word, atSentenceStart: atSentenceStart),
           !suppressionProvider(word, replacement) {
            return (word, replacement)
        }

        if let contextual = ContextualScorer.replacement(history: recentWords, current: word),
           !suppressionProvider(contextual.original, contextual.replacement) {
            return contextual
        }

        if let contextual = contextualSpellingProvider?(recentWords, word),
           !suppressionProvider(contextual.original, contextual.replacement) {
            return contextual
        }

        guard let neural = neuralReplacement(for: word),
              !suppressionProvider(neural.original, neural.replacement) else { return nil }
        return neural
    }

    private func neuralReplacement(for word: String) -> (original: String, replacement: String)? {
        guard let rerankProvider,
              let decision = rerankProvider(Array(recentWords.suffix(4)) + [word]),
              decision.confidence >= ContextReranker.automaticThreshold,
              decision.action != .keep else { return nil }

        func preserveCase(_ source: String, _ replacement: String) -> String {
            guard source.first?.isUppercase == true, let first = replacement.first else { return replacement }
            return first.uppercased() + replacement.dropFirst()
        }

        if decision.action == .thereToTheir,
           let previous = recentWords.last,
           previous.lowercased() == "there" {
            return (previous + " " + word, preserveCase(previous, "their") + " " + word)
        }
        if decision.action == .ofToHave,
           let previous = recentWords.last,
           ["should", "could", "would"].contains(previous.lowercased()),
           word.lowercased() == "of" {
            return (previous + " " + word, previous + " have")
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
        return (original, replacement)
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
        guard !word.isEmpty else { return nil }
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
