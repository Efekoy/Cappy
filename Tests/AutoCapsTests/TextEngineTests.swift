import Testing
@testable import AutoCaps

struct TextEngineTests {
    private let all = TypingFeatures()

    @Test func capitalisesAtBeginningOfEmptyField() {
        var engine = TextEngine(); engine.applyContext("")
        #expect(engine.handle(character: "h", features: all) == .replaceCurrentEvent(with: "H"))
        #expect(engine.handle(character: "i", features: all) == .pass)
    }

    @Test func capitalisesAfterSentencePunctuationAndWhitespace() {
        for prefix in ["Hello. ", "Really? ", "Nice!   "] {
            var engine = TextEngine(); engine.applyContext(prefix)
            #expect(engine.handle(character: "t", features: all) == .replaceCurrentEvent(with: "T"))
        }
    }

    @Test func periodRequiresWhitespace() {
        var engine = TextEngine(); engine.applyContext("example.")
        #expect(engine.handle(character: "c", features: all) == .pass)
    }

    @Test func leadingNumbersAndPunctuationDoNotConsumeCapitalisation() {
        var engine = TextEngine(); engine.applyContext("")
        for character in "(123) " { _ = engine.handle(character: character, features: all) }
        #expect(engine.handle(character: "h", features: all) == .replaceCurrentEvent(with: "H"))
    }

    @Test func returnStartsNewSentence() {
        var engine = TextEngine(); engine.applyContext("hello")
        #expect(engine.handle(character: "\n", features: all) == .pass)
        #expect(engine.handle(character: "w", features: all) == .replaceCurrentEvent(with: "W"))
    }

    @Test func doubleSpaceAndFollowingCapital() {
        var engine = TextEngine(); engine.applyContext("")
        for character in "hello" { _ = engine.handle(character: character, features: all) }
        #expect(engine.handle(character: " ", features: all) == .pass)
        #expect(engine.handle(character: " ", features: all) == .edit(TextEdit(backspaces: 1, insertion: ". ")))
        #expect(engine.handle(character: "w", features: all) == .replaceCurrentEvent(with: "W"))
    }

    @Test func doubleSpaceDoesNotTriggerAfterPunctuation() {
        var engine = TextEngine(); engine.applyContext("hello.")
        #expect(engine.handle(character: " ", features: all) == .pass)
        #expect(engine.handle(character: " ", features: all) == .pass)
    }

    @Test func safeContractions() {
        let cases = [("theyre", "they're "), ("youve", "you've "), ("dont", "don't "),
                     ("couldnt", "couldn't "), ("im", "I'm "), ("ive", "I've ")]
        for (input, expected) in cases {
            var engine = TextEngine(); engine.applyContext("Earlier ")
            for character in input { _ = engine.handle(character: character, features: all) }
            #expect(engine.handle(character: " ", features: all) == .edit(TextEdit(backspaces: input.count, insertion: expected)))
        }
    }

    @Test func contractionPreservesLeadingCapital() {
        var engine = TextEngine(); engine.applyContext("")
        for character in "Theyre" { _ = engine.handle(character: character, features: all) }
        #expect(engine.handle(character: ",", features: all) == .edit(TextEdit(backspaces: 6, insertion: "They're,")))
    }

    @Test func standalonePronounIIsCapitalised() {
        var engine = TextEngine(); engine.applyContext("Today ")
        #expect(engine.handle(character: "i", features: all) == .pass)
        #expect(engine.handle(character: " ", features: all) == .edit(TextEdit(backspaces: 1, insertion: "I ")))
    }

    @Test func ambiguousWordsAreNotChanged() {
        for input in ["were", "well", "shell", "hell"] {
            var engine = TextEngine(); engine.applyContext("")
            for character in input { _ = engine.handle(character: character, features: all) }
            #expect(engine.handle(character: " ", features: all) == .pass)
        }
    }

    @Test func requestedCommonContractions() {
        for (input, expected) in [
            ("cant", "can't "), ("ill", "I'll "), ("its", "it's "),
            ("wont", "won't "), ("thats", "that's "), ("whats", "what's "),
            ("shes", "she's "), ("shouldve", "should've ")
        ] {
            var engine = TextEngine(); engine.applyContext("Earlier ")
            for letter in input { _ = engine.handle(character: letter, features: all) }
            #expect(engine.handle(character: " ", features: all) == .edit(TextEdit(backspaces: input.count, insertion: expected)))
        }
    }

    @Test func backspaceImmediatelyAfterAutoCapitalisationOptsOutOnce() {
        var engine = TextEngine(); engine.applyContext("")
        #expect(engine.handle(character: "h", features: all) == .replaceCurrentEvent(with: "H"))
        engine.handleBackspace()
        engine.applyContext("")
        #expect(engine.handle(character: "h", features: all) == .pass)
        #expect(engine.handle(character: "e", features: all) == .pass)
    }

    @Test func differentLetterAfterDeletingAutoCapitalStillCapitalises() {
        var engine = TextEngine(); engine.applyContext("")
        #expect(engine.handle(character: "h", features: all) == .replaceCurrentEvent(with: "H"))
        engine.handleBackspace()
        engine.applyContext("")
        #expect(engine.handle(character: "w", features: all) == .replaceCurrentEvent(with: "W"))
    }

    @Test func laterBackspaceDoesNotOptOut() {
        var engine = TextEngine(); engine.applyContext("")
        #expect(engine.handle(character: "h", features: all) == .replaceCurrentEvent(with: "H"))
        #expect(engine.handle(character: "i", features: all) == .pass)
        engine.handleBackspace()
        engine.applyContext("")
        #expect(engine.handle(character: "h", features: all) == .replaceCurrentEvent(with: "H"))
    }

    @Test func disabledFeaturesPassThrough() {
        var engine = TextEngine(); engine.applyContext("")
        let off = TypingFeatures(autoCapitalisation: false, doubleSpacePeriod: false, contractions: false)
        for character in "dont" { #expect(engine.handle(character: character, features: off) == .pass) }
        #expect(engine.handle(character: " ", features: off) == .pass)
        #expect(engine.handle(character: " ", features: off) == .pass)
    }

    @Test func unknownContextIsConservative() {
        var engine = TextEngine(); engine.applyContext(nil)
        #expect(engine.handle(character: "h", features: all) == .pass)
    }

    @Test func typoCorrectionRunsOnlyAtWordBoundary() {
        var engine = TextEngine(); engine.applyContext("Earlier ")
        var calls = 0
        for character in "teh" {
            #expect(engine.handle(character: character, features: all, typoSuggestion: { _ in
                calls += 1
                return "the"
            }) == .pass)
        }
        #expect(calls == 0)
        #expect(engine.handle(character: " ", features: all, typoSuggestion: { word in
            calls += 1
            return word == "teh" ? "the" : nil
        }) == .edit(TextEdit(backspaces: 3, insertion: "the ")))
        #expect(calls == 1)
    }

    @Test func typoCorrectionWorksWithPunctuationAndReturn() {
        for separator in [",", "\n"] {
            var engine = TextEngine(); engine.applyContext("Earlier ")
            for character in "recieve" { _ = engine.handle(character: character, features: all) }
            #expect(engine.handle(character: Character(separator), features: all, typoSuggestion: { _ in "receive" })
                == .edit(TextEdit(backspaces: 7, insertion: "receive" + separator)))
        }
    }

    @Test func contractionsTakePriorityOverSpellChecker() {
        var engine = TextEngine(); engine.applyContext("Earlier ")
        for character in "cant" { _ = engine.handle(character: character, features: all) }
        #expect(engine.handle(character: " ", features: all, typoSuggestion: { _ in
            Issue.record("Spell checker must not run when a contraction rule applies")
            return "can"
        }) == .edit(TextEdit(backspaces: 4, insertion: "can't ")))
    }

    @Test func typoCanFlowIntoContraction() {
        var engine = TextEngine(); engine.applyContext("Earlier ")
        for character in "catn" { _ = engine.handle(character: character, features: all) }
        #expect(engine.handle(character: " ", features: all, typoSuggestion: { _ in "cant" })
            == .edit(TextEdit(backspaces: 4, insertion: "can't ")))
    }

    @Test func typoFixesCanBeDisabled() {
        var engine = TextEngine(); engine.applyContext("Earlier ")
        var features = all; features.typoFixes = false
        for character in "teh" { _ = engine.handle(character: character, features: features) }
        #expect(engine.handle(character: " ", features: features, typoSuggestion: { _ in
            Issue.record("Disabled spell checker must not run")
            return "the"
        }) == .pass)
    }

    @Test func typoFixesSkipProtectedAndNameLikeWords() {
        for prefix in ["https://", "name@", "file_", "code-"] {
            var engine = TextEngine(); engine.applyContext(prefix)
            for character in "teh" { _ = engine.handle(character: character, features: all) }
            #expect(engine.handle(character: " ", features: all, typoSuggestion: { _ in
                Issue.record("Protected token must not be spell checked")
                return "the"
            }) == .pass)
        }

        var name = TextEngine(); name.applyContext("Earlier ")
        for character in "Helo" { _ = name.handle(character: character, features: all) }
        #expect(name.handle(character: " ", features: all, typoSuggestion: { _ in
            Issue.record("Manually capitalised word must not be spell checked")
            return "hello"
        }) == .pass)

        var mixed = TextEngine(); mixed.applyContext("Earlier ")
        for character in "iPhone" { _ = mixed.handle(character: character, features: all) }
        #expect(mixed.handle(character: " ", features: all, typoSuggestion: { _ in
            Issue.record("Mixed-case word must not be spell checked")
            return "phone"
        }) == .pass)
    }

    @Test func typoFixesDoNotChangeEmailAndDomainSegments() {
        for separator in ["@", ".", "_", "/"] {
            var engine = TextEngine(); engine.applyContext("Earlier ")
            for character in "teh" { _ = engine.handle(character: character, features: all) }
            #expect(engine.handle(character: Character(separator), features: all, typoSuggestion: { _ in
                Issue.record("Token joiner must not trigger a spelling replacement")
                return "the"
            }) == .pass)
            for character in "com" { _ = engine.handle(character: character, features: all) }
            #expect(engine.handle(character: " ", features: all, typoSuggestion: { _ in
                Issue.record("Remainder of protected token must not be spell checked")
                return "come"
            }) == .pass)
        }
    }

    @Test func typoBeforeSentencePeriodIsCorrectedAfterSpace() {
        var engine = TextEngine(); engine.applyContext("Earlier ")
        for character in "teh" { _ = engine.handle(character: character, features: all) }
        #expect(engine.handle(character: ".", features: all, typoSuggestion: { _ in
            Issue.record("A period must wait to determine whether this is a domain")
            return "the"
        }) == .pass)
        #expect(engine.handle(character: " ", features: all, typoSuggestion: { _ in "the" })
            == .edit(TextEdit(backspaces: 4, insertion: "the. ")))
        #expect(engine.handle(character: "w", features: all) == .replaceCurrentEvent(with: "W"))
    }

    @Test func typoBeforePeriodIsNotChangedWhenDomainContinues() {
        var engine = TextEngine(); engine.applyContext("Earlier ")
        for character in "teh" { _ = engine.handle(character: character, features: all) }
        #expect(engine.handle(character: ".", features: all) == .pass)
        for character in "com" { _ = engine.handle(character: character, features: all) }
        #expect(engine.handle(character: " ", features: all, typoSuggestion: { _ in
            Issue.record("Domain segments must not be spell checked")
            return "the"
        }) == .pass)
    }

    @Test func typoAfterSentenceContextIsNotTreatedAsDomain() {
        var engine = TextEngine(); engine.applyContext("Hello. ")
        for character in "teh" { _ = engine.handle(character: character, features: all) }
        #expect(engine.handle(character: " ", features: all, typoSuggestion: { _ in "the" })
            == .edit(TextEdit(backspaces: 3, insertion: "The ")))
    }

    @Test func systemSuggestionPolicyRejectsUnsafeCandidates() {
        #expect(TypoCorrectionPolicy.accepted(original: "teh", suggestion: "the") == "the")
        #expect(TypoCorrectionPolicy.accepted(original: "recieve", suggestion: "receive") == "receive")
        #expect(TypoCorrectionPolicy.accepted(original: "implementaiotn", suggestion: "implementation") == "implementation")
        #expect(TypoCorrectionPolicy.accepted(original: "Teh", suggestion: "the") == "The")
        #expect(TypoCorrectionPolicy.accepted(original: "teh", suggestion: "the cat") == nil)
        #expect(TypoCorrectionPolicy.accepted(original: "teh", suggestion: "the.example") == nil)
        #expect(TypoCorrectionPolicy.accepted(original: "teh", suggestion: "somethingverydifferent") == nil)
    }
}
