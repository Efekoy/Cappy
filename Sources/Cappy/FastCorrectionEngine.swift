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
    static let maximumWordLength = 32
    static let maximumContextUTF16Length = 96

    private static let commonReplacements: [String: String] = [
        "alot": "a lot",
        "definately": "definitely",
        "helllo": "hello",
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

    mutating func invalidate() {
        currentWord.removeAll(keepingCapacity: true)
        tokenIsProtected = false
        wordOverflowed = false
        wordBeganSentence = false
        nextWordBeginsSentence = true
        generation &+= 1
    }

    mutating func synchronize(leftContext: String?) {
        currentWord.removeAll(keepingCapacity: true)
        tokenIsProtected = false
        wordOverflowed = false
        wordBeganSentence = false

        guard let leftContext else {
            nextWordBeginsSentence = false
            return
        }

        nextWordBeginsSentence = true
        _ = consume(leftContext)
    }

    mutating func consume(_ text: String) -> FastCorrection? {
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
               let replacement = Self.replacement(for: completedWord, atSentenceStart: wordBeganSentence) {
                correction = FastCorrection(
                    original: completedWord,
                    replacement: replacement,
                    suffix: String(character)
                )
            }

            if !completedWord.isEmpty {
                nextWordBeginsSentence = false
            }
            if Self.endsSentence(character) {
                nextWordBeginsSentence = true
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

    private static func replacement(for word: String, atSentenceStart: Bool) -> String? {
        guard !word.isEmpty else { return nil }
        let lowercased = word.lowercased()
        var replacement = commonReplacements[lowercased] ?? apostropheReplacements[lowercased]

        if replacement == nil, atSentenceStart, word.first?.isLowercase == true {
            replacement = capitalizingFirstLetter(of: word)
        }
        guard var replacement, replacement != word else { return nil }

        if atSentenceStart {
            replacement = capitalizingFirstLetter(of: replacement)
        } else if word.first?.isUppercase == true {
            replacement = capitalizingFirstLetter(of: replacement)
        }
        return replacement == word ? nil : replacement
    }

    private static func capitalizingFirstLetter(of text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func endsSentence(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?" || character == "\n"
    }

    private static func isWordLetter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.letters.contains)
    }
}
