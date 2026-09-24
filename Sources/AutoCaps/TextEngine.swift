import Foundation

struct TypingFeatures: Equatable {
    var autoCapitalisation = true
    var doubleSpacePeriod = true
    var contractions = true
    var typoFixes = true
}

struct TextEdit: Equatable {
    var backspaces: Int = 0
    var insertion: String
}

struct TypoRequest: Equatable {
    let word: String
    let wasAutoCapitalised: Bool
}

enum TextDecision: Equatable {
    case pass
    case replaceCurrentEvent(with: String)
    case edit(TextEdit)
}

/// A small, UI-independent state machine. It owns only the current short word
/// and a few booleans describing nearby punctuation.
struct TextEngine {
    static let maximumWordLength = 32

    /// This is intentionally editable. Some requested corrections (notably
    /// "its" and "ill") are ambiguous in English; the user has opted into them.
    /// Other ambiguous words such as "were", "well", and "shell" stay excluded.
    static let contractionDictionary: [String: String] = [
        "theyre": "they're", "youre": "you're", "youve": "you've",
        "youll": "you'll", "youd": "you'd", "dont": "don't",
        "doesnt": "doesn't", "didnt": "didn't", "cant": "can't",
        "couldnt": "couldn't", "wouldnt": "wouldn't", "shouldnt": "shouldn't",
        "isnt": "isn't", "arent": "aren't", "wasnt": "wasn't",
        "werent": "weren't", "hasnt": "hasn't", "havent": "haven't",
        "hadnt": "hadn't", "mustnt": "mustn't", "neednt": "needn't",
        "wont": "won't", "wontve": "won't've", "shouldve": "should've",
        "couldve": "could've", "wouldve": "would've", "mightve": "might've",
        "mustve": "must've", "theyve": "they've",
        "weve": "we've",
        "thats": "that's", "whats": "what's", "whos": "who's",
        "wheres": "where's", "whens": "when's", "whys": "why's",
        "hows": "how's", "theres": "there's", "heres": "here's",
        "lets": "let's", "hes": "he's", "shes": "she's",
        "itd": "it'd", "itll": "it'll", "its": "it's",
        "im": "I'm", "ive": "I've", "ill": "I'll",
        "i": "I"
    ]

    private(set) var currentWord = ""
    private var shouldCapitaliseNextLetter = false
    private var pendingSentenceTerminator = false
    private var doubleSpaceEligible = false
    private var needsContext = true
    private var lastAutoCapitalisedLetter: Character?
    private var suppressCapitalisationFor: Character?
    private var currentWordWasAutoCapitalised = false
    private var protectedToken = false
    private var pendingPeriodWord: String?
    private var pendingPeriodWordWasAutoCapitalised = false
    private(set) var recentCorrection: RecentCorrection?
    private var rejectedWord: String?
    var needsExternalContext: Bool { needsContext }

    mutating func invalidateContext() {
        recentCorrection = nil
        rejectedWord = nil
        currentWord.removeAll(keepingCapacity: true)
        shouldCapitaliseNextLetter = false
        pendingSentenceTerminator = false
        doubleSpaceEligible = false
        needsContext = true
        lastAutoCapitalisedLetter = nil
        suppressCapitalisationFor = nil
        currentWordWasAutoCapitalised = false
        protectedToken = false
        pendingPeriodWord = nil
        pendingPeriodWordWasAutoCapitalised = false
    }

    /// Only an immediate Backspace after AutoCaps changed a letter can opt out
    /// of that capitalization. Subsequent navigation or typing cancels it.
    mutating func handleBackspace() {
        let optedOutLetter = lastAutoCapitalisedLetter
        invalidateContext()
        suppressCapitalisationFor = optedOutLetter
    }

    /// Seeds the engine with at most the short string immediately before the
    /// insertion point. Nil means the host exposed no context, so no guess is made.
    mutating func applyContext(_ context: String?) {
        recentCorrection = nil
        rejectedWord = nil
        currentWord.removeAll(keepingCapacity: true)
        currentWordWasAutoCapitalised = false
        pendingSentenceTerminator = false
        doubleSpaceEligible = false
        needsContext = false
        pendingPeriodWord = nil
        pendingPeriodWordWasAutoCapitalised = false

        guard let context else {
            shouldCapitaliseNextLetter = false
            return
        }

        let tail = String(context.suffix(64))
        shouldCapitaliseNextLetter = Self.contextStartsSentence(tail)
        protectedToken = tail.last?.isWhitespace == true ? false :
            (tail.split(whereSeparator: \.isWhitespace).last.map { token in
                token.contains(where: Self.protectsToken)
            } ?? false)

        var trailingWord = ""
        for character in tail.reversed() {
            guard Self.isWordCharacter(character) else { break }
            trailingWord.insert(character, at: trailingWord.startIndex)
            if trailingWord.count == Self.maximumWordLength { break }
        }
        currentWord = trailingWord

        if tail.last == " " {
            doubleSpaceEligible = tail.dropLast().last.map(Self.isWordCharacter) ?? false
        }
    }

    mutating func handle(
        character original: Character,
        features: TypingFeatures,
        typoSuggestion: (String) -> String? = { _ in nil }
    ) -> TextDecision {
        recentCorrection = nil
        if needsContext { applyContext(nil) }
        lastAutoCapitalisedLetter = nil
        if !Self.isLetter(original) { suppressCapitalisationFor = nil }
        if original == "\n" || original == "\r" { return handleLineBreak(original, features: features, typoSuggestion: typoSuggestion) }
        if original == " " { return handleSpace(features: features, typoSuggestion: typoSuggestion) }
        pendingPeriodWord = nil
        if Self.isLetter(original) { return handleLetter(original, features: features) }
        if Self.isWordCharacter(original) {
            appendToWord(contentsOf: String(original))
            pendingSentenceTerminator = false
            doubleSpaceEligible = false
            return .pass
        }
        return handlePunctuation(original, features: features, typoSuggestion: typoSuggestion)
    }

    private mutating func handleLetter(_ original: Character, features: TypingFeatures) -> TextDecision {
        var emitted = String(original)
        let optOut = suppressCapitalisationFor == original
        suppressCapitalisationFor = nil
        if features.autoCapitalisation && shouldCapitaliseNextLetter && !optOut {
            emitted = emitted.uppercased()
            if emitted != String(original) {
                lastAutoCapitalisedLetter = original
                if currentWord.isEmpty { currentWordWasAutoCapitalised = true }
            }
        }
        shouldCapitaliseNextLetter = false
        pendingSentenceTerminator = false
        doubleSpaceEligible = false
        appendToWord(contentsOf: emitted)
        return emitted == String(original) ? .pass : .replaceCurrentEvent(with: emitted)
    }

    private mutating func handleSpace(features: TypingFeatures, typoSuggestion: (String) -> String?) -> TextDecision {
        defer { rejectedWord = nil }
        let deferredWord = pendingPeriodWord
        let deferredCorrection = pendingPeriodWord.flatMap { word in
            typoReplacement(for: word, wasAutoCapitalised: pendingPeriodWordWasAutoCapitalised,
                inProtectedToken: false, features: features, typoSuggestion: typoSuggestion)
        }
        let deferredWordLength = pendingPeriodWord?.count ?? 0
        pendingPeriodWord = nil
        if features.doubleSpacePeriod && doubleSpaceEligible {
            currentWord.removeAll(keepingCapacity: true)
            currentWordWasAutoCapitalised = false
            protectedToken = false
            doubleSpaceEligible = false
            pendingSentenceTerminator = false
            shouldCapitaliseNextLetter = true
            return .edit(TextEdit(backspaces: 1, insertion: ". "))
        }

        let completedWord = currentWord
        let wasAfterWord = !completedWord.isEmpty
        let replacement = replacement(for: completedWord, features: features, typoSuggestion: typoSuggestion)
        currentWord.removeAll(keepingCapacity: true)
        currentWordWasAutoCapitalised = false
        protectedToken = false
        doubleSpaceEligible = wasAfterWord
        if pendingSentenceTerminator { shouldCapitaliseNextLetter = true }
        pendingSentenceTerminator = false
        if let replacement {
            return correctionEdit(original: completedWord, replacement: replacement, suffix: " ")
        }
        if let deferredCorrection {
            recentCorrection = RecentCorrection(original: deferredWord ?? "", replacement: deferredCorrection, suffix: ". ")
            return .edit(TextEdit(backspaces: deferredWordLength + 1, insertion: deferredCorrection + ". "))
        }
        return .pass
    }

    private mutating func handleLineBreak(_ original: Character, features: TypingFeatures, typoSuggestion: (String) -> String?) -> TextDecision {
        defer { rejectedWord = nil }
        let deferredCorrection = pendingPeriodWord.flatMap { word in
            typoReplacement(for: word, wasAutoCapitalised: pendingPeriodWordWasAutoCapitalised,
                inProtectedToken: false, features: features, typoSuggestion: typoSuggestion)
        }
        let deferredWordLength = pendingPeriodWord?.count ?? 0
        pendingPeriodWord = nil
        let completedWord = currentWord
        let replacement = replacement(for: completedWord, features: features, typoSuggestion: typoSuggestion)
        currentWord.removeAll(keepingCapacity: true)
        currentWordWasAutoCapitalised = false
        protectedToken = false
        doubleSpaceEligible = false
        pendingSentenceTerminator = false
        shouldCapitaliseNextLetter = true
        if let replacement {
            return .edit(TextEdit(backspaces: completedWord.count, insertion: replacement + String(original)))
        }
        if let deferredCorrection {
            return .edit(TextEdit(backspaces: deferredWordLength + 1, insertion: deferredCorrection + "." + String(original)))
        }
        return .pass
    }

    private mutating func handlePunctuation(_ punctuation: Character, features: TypingFeatures, typoSuggestion: (String) -> String?) -> TextDecision {
        let completedWord = currentWord
        // A period may start a domain, and @ / _ etc. may join an email, URL,
        // or identifier. Keep contraction rules, but never spell-correct here.
        let replacement: String?
        if Self.protectsToken(punctuation) {
            replacement = features.contractions && completedWord != rejectedWord ? contraction(for: completedWord) : nil
        } else {
            replacement = self.replacement(for: completedWord, features: features, typoSuggestion: typoSuggestion)
        }
        if punctuation == "." && replacement == nil && !protectedToken && !completedWord.isEmpty {
            pendingPeriodWord = completedWord
            pendingPeriodWordWasAutoCapitalised = currentWordWasAutoCapitalised
        }
        currentWord.removeAll(keepingCapacity: true)
        currentWordWasAutoCapitalised = false
        doubleSpaceEligible = false
        if Self.protectsToken(punctuation) { protectedToken = true }
        if punctuation == "." || punctuation == "?" || punctuation == "!" {
            pendingSentenceTerminator = true
        } else if !Self.isOpeningPunctuation(punctuation) {
            pendingSentenceTerminator = false
        }
        if let replacement {
            return correctionEdit(original: completedWord, replacement: replacement, suffix: String(punctuation))
        }
        return .pass
    }

    private func replacement(for word: String, features: TypingFeatures, typoSuggestion: (String) -> String?) -> String? {
        guard word != rejectedWord else { return nil }
        if features.contractions, let contraction = contraction(for: word) { return contraction }
        return typoReplacement(for: word, wasAutoCapitalised: currentWordWasAutoCapitalised,
            inProtectedToken: protectedToken, features: features, typoSuggestion: typoSuggestion)
    }

    private func typoReplacement(
        for word: String,
        wasAutoCapitalised: Bool,
        inProtectedToken: Bool,
        features: TypingFeatures,
        typoSuggestion: (String) -> String?
    ) -> String? {
        guard features.typoFixes,
              word != rejectedWord,
              !inProtectedToken,
              (3...24).contains(word.count),
              word.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) && $0.isASCII }),
              !word.dropFirst().contains(where: \.isUppercase),
              word.first?.isUppercase != true || wasAutoCapitalised,
              let candidate = typoSuggestion(word) else { return nil }
        guard let corrected = TypoCorrectionPolicy.accepted(original: word, suggestion: candidate) else { return nil }
        // A spelling suggestion can itself be a missing-apostrophe contraction
        // (for example catn -> cant); let the explicit rule finish the job.
        if features.contractions, let contraction = contraction(for: corrected) { return contraction }
        return corrected
    }

    private mutating func appendToWord(contentsOf text: String) {
        currentWord.append(contentsOf: text)
        if currentWord.count > Self.maximumWordLength {
            currentWord = String(currentWord.suffix(Self.maximumWordLength))
        }
    }

    private mutating func correctionEdit(original: String, replacement: String, suffix: String) -> TextDecision {
        if original != replacement {
            recentCorrection = RecentCorrection(original: original, replacement: replacement, suffix: suffix)
        }
        return .edit(TextEdit(backspaces: original.count, insertion: replacement + suffix))
    }

    mutating func restore(_ correction: RecentCorrection, removingSpace: Bool) {
        invalidateContext()
        applyContext(correction.restoredText(removingSpace: removingSpace))
        rejectedWord = correction.restoredText(removingSpace: removingSpace) == correction.original ? correction.original : nil
    }

    mutating func discardRecentCorrection() { recentCorrection = nil }

    func typoRequestAtBoundary(features: TypingFeatures) -> TypoRequest? {
        let word = currentWord
        guard features.typoFixes,
              word != rejectedWord,
              !protectedToken,
              contraction(for: word) == nil,
              (3...24).contains(word.count),
              word.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) && $0.isASCII }),
              !word.dropFirst().contains(where: \.isUppercase),
              word.first?.isUppercase != true || currentWordWasAutoCapitalised else { return nil }
        return TypoRequest(word: word, wasAutoCapitalised: currentWordWasAutoCapitalised)
    }

    mutating func applyDelayedTypoSuggestion(
        _ suggestion: String,
        request: TypoRequest,
        suffix: String,
        features: TypingFeatures
    ) -> (edit: TextEdit, correction: RecentCorrection)? {
        guard features.typoFixes,
              let accepted = TypoCorrectionPolicy.accepted(original: request.word, suggestion: suggestion) else { return nil }
        let replacement = features.contractions ? contraction(for: accepted) ?? accepted : accepted
        let correction = RecentCorrection(original: request.word, replacement: replacement, suffix: suffix)
        recentCorrection = correction
        return (TextEdit(backspaces: request.word.count + suffix.count, insertion: replacement + suffix), correction)
    }

    private func contraction(for word: String) -> String? {
        guard !word.isEmpty, let canonical = Self.contractionDictionary[word.lowercased()] else { return nil }
        if word.allSatisfy({ !$0.isLetter || $0.isUppercase }) { return canonical.uppercased() }
        if word.first?.isUppercase == true { return canonical.prefix(1).uppercased() + canonical.dropFirst() }
        return canonical
    }

    private static func contextStartsSentence(_ context: String) -> Bool {
        if context.isEmpty { return true }
        if !context.contains(where: isLetter) { return true }
        if context.last == "\n" || context.last == "\r" { return true }
        guard context.last?.isWhitespace == true else { return false }
        let preceding = context.reversed().drop(while: { $0.isWhitespace }).first
        return preceding == "." || preceding == "?" || preceding == "!"
    }

    private static func isLetter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.letters.contains)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    private static func isOpeningPunctuation(_ character: Character) -> Bool {
        "([{'\"“‘".contains(character)
    }

    private static func protectsToken(_ character: Character) -> Bool {
        ".@/#_\\:-".contains(character)
    }
}
