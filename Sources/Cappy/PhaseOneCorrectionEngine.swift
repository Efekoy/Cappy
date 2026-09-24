import Foundation

struct PhaseOneCorrection: Equatable {
    let original: String
    let replacement: String
    let suffix: String

    var originalUTF16Length: Int { (original as NSString).length }
    var replacementUTF16Length: Int { (replacement as NSString).length }
    var suffixUTF16Length: Int { (suffix as NSString).length }
}

enum CorrectionRangePlanner {
    static func sourceRange(for correction: PhaseOneCorrection, selection: NSRange) -> NSRange? {
        let consumedLength = correction.originalUTF16Length + correction.suffixUTF16Length
        guard selection.location != NSNotFound,
              selection.length == 0,
              selection.location >= consumedLength else { return nil }
        return NSRange(
            location: selection.location - consumedLength,
            length: correction.originalUTF16Length
        )
    }

    static func undoRange(for correction: PhaseOneCorrection, sourceRange: NSRange) -> NSRange {
        NSRange(
            location: sourceRange.location,
            length: correction.replacementUTF16Length + correction.suffixUTF16Length
        )
    }
}

/// The deliberately small first milestone engine. It retains only the active
/// word and never stores sentence history.
struct PhaseOneCorrectionEngine {
    static let maximumWordLength = 32

    private(set) var currentWord = ""
    private(set) var generation: UInt64 = 0
    private var tokenIsProtected = false
    private var wordOverflowed = false

    mutating func invalidate() {
        currentWord.removeAll(keepingCapacity: true)
        tokenIsProtected = false
        wordOverflowed = false
        generation &+= 1
    }

    mutating func consume(_ text: String) -> PhaseOneCorrection? {
        var correction: PhaseOneCorrection?

        for character in text {
            if Self.isWordLetter(character) {
                if !wordOverflowed { currentWord.append(character) }
                if currentWord.count > Self.maximumWordLength {
                    currentWord.removeAll(keepingCapacity: true)
                    wordOverflowed = true
                }
                continue
            }

            if character.isWhitespace,
               !tokenIsProtected,
               !wordOverflowed,
               currentWord.lowercased() == "definately" {
                let replacement = currentWord.first?.isUppercase == true ? "Definitely" : "definitely"
                correction = PhaseOneCorrection(
                    original: currentWord,
                    replacement: replacement,
                    suffix: String(character)
                )
            }
            currentWord.removeAll(keepingCapacity: true)
            if character.isWhitespace {
                tokenIsProtected = false
                wordOverflowed = false
            } else {
                tokenIsProtected = true
            }
        }

        return correction
    }

    private static func isWordLetter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.letters.contains)
    }
}
