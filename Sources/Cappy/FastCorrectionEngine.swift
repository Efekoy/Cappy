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

    static let maximumWordLength = 32
    static let maximumContextUTF16Length = 96

    private static let commonReplacements: [String: String] = [
        "alot": "a lot",
        "definately": "definitely",
        "helllo": "hello",
        "i": "I",
        "occured": "occurred",
        "recieve": "receive",
        "seperate": "separate",
        "teh": "the",
        "tge": "the",
        "untill": "until",
        "welocme": "welcome",
        "yhe": "the"
    ]

    private static let apostropheReplacements: [String: String] = [
        "arent": "aren't",
        "cant": "can't",
        "couldnt": "couldn't",
        "didnt": "didn't",
        "doesnt": "doesn't",
        "dont": "don't",
        "hadnt": "hadn't",
        "hasnt": "hasn't",
        "havent": "haven't",
        "im": "I'm",
        "isnt": "isn't",
        "shouldnt": "shouldn't",
        "theyre": "they're",
        "wasnt": "wasn't",
        "werent": "weren't",
        "wont": "won't",
        "wouldnt": "wouldn't",
        "youre": "you're"
    ]

    private(set) var currentWord = ""
    private(set) var generation: UInt64 = 0
    private var tokenIsProtected = false
    private var wordOverflowed = false
    private var wordBeganSentence = false
    private var nextWordBeginsSentence = true
    private let candidateProvider: CandidateProvider
    private let suppressionProvider: SuppressionProvider
    private var recentWords: [String] = []

    init(
        candidateProvider: @escaping CandidateProvider = { _ in [] },
        suppressionProvider: @escaping SuppressionProvider = { _, _ in false }
    ) {
        self.candidateProvider = candidateProvider
        self.suppressionProvider = suppressionProvider
    }

    mutating func invalidate() {
        currentWord.removeAll(keepingCapacity: true)
        tokenIsProtected = false
        wordOverflowed = false
        wordBeganSentence = false
        nextWordBeginsSentence = true
        recentWords.removeAll(keepingCapacity: true)
        generation &+= 1
    }

    mutating func synchronize(leftContext: String?) {
        currentWord.removeAll(keepingCapacity: true)
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
            if Self.isWordLetter(character) {
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

            let completedWord = currentWord
            if character.isWhitespace,
               !tokenIsProtected,
               !wordOverflowed,
               allowsCorrection,
               let replacement = bestReplacement(for: completedWord, atSentenceStart: wordBeganSentence) {
                correction = FastCorrection(
                    original: replacement.original,
                    replacement: replacement.replacement,
                    suffix: String(character)
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
            if Self.endsSentence(character) {
                nextWordBeginsSentence = true
                recentWords.removeAll(keepingCapacity: true)
            }
            currentWord.removeAll(keepingCapacity: true)
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

        guard let contextual = ContextualScorer.replacement(history: recentWords, current: word),
              !suppressionProvider(contextual.original, contextual.replacement) else { return nil }
        return contextual
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
        var replacement = Self.commonReplacements[lowercased] ?? Self.apostropheReplacements[lowercased]

        if replacement == nil, Self.hasSimpleCasing(word) {
            replacement = conservativeDictionaryReplacement(for: lowercased)
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

    private func conservativeDictionaryReplacement(for word: String) -> String? {
        guard word.count >= 4,
              word.unicodeScalars.allSatisfy(CharacterSet.lowercaseLetters.contains) else { return nil }

        let suggestions = candidateProvider(word).prefix(5).map { $0.lowercased() }
        guard let first = suggestions.first,
              Self.isSafeSingleEdit(from: word, to: first) else { return nil }
        return first
    }

    private static func isSafeSingleEdit(from observed: String, to candidate: String) -> Bool {
        guard candidate != observed,
              candidate.unicodeScalars.allSatisfy(CharacterSet.lowercaseLetters.contains) else { return false }

        let source = Array(observed)
        let target = Array(candidate)
        let lengthDifference = target.count - source.count
        guard abs(lengthDifference) <= 1 else { return false }

        if lengthDifference == 0 {
            let mismatches = source.indices.filter { source[$0] != target[$0] }
            if mismatches.count == 2,
               mismatches[1] == mismatches[0] + 1,
               source[mismatches[0]] == target[mismatches[1]],
               source[mismatches[1]] == target[mismatches[0]] {
                return true
            }
            if mismatches.count == 1 {
                return keyboardNeighbours[source[mismatches[0]], default: []].contains(target[mismatches[0]])
            }
            return false
        }

        // A single missing or extra letter is a high-confidence edit only when
        // the rest of the word is identical.
        let longer = lengthDifference > 0 ? target : source
        let shorter = lengthDifference > 0 ? source : target
        var longIndex = 0
        var shortIndex = 0
        var skipped = false
        while longIndex < longer.count, shortIndex < shorter.count {
            if longer[longIndex] == shorter[shortIndex] {
                longIndex += 1
                shortIndex += 1
            } else if !skipped {
                skipped = true
                longIndex += 1
            } else {
                return false
            }
        }
        return true
    }

    private static let keyboardNeighbours: [Character: Set<Character>] = {
        let rows = [Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm")]
        var result: [Character: Set<Character>] = [:]
        for (rowIndex, row) in rows.enumerated() {
            for (column, key) in row.enumerated() {
                var neighbours = Set<Character>()
                for adjacentRowIndex in max(0, rowIndex - 1)...min(rows.count - 1, rowIndex + 1) {
                    let adjacentRow = rows[adjacentRowIndex]
                    let lowerBound = max(0, min(column - 1, adjacentRow.count - 1))
                    let upperBound = min(adjacentRow.count - 1, column + 1)
                    for adjacentColumn in lowerBound...upperBound
                    where !(adjacentRowIndex == rowIndex && adjacentColumn == column) {
                        neighbours.insert(adjacentRow[adjacentColumn])
                    }
                }
                result[key] = neighbours
            }
        }
        return result
    }()

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
