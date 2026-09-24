import Testing
@testable import AutoCaps

struct CorrectionUndoTests {
    let features = TypingFeatures()

    private func corrected(_ word: String, suffix: String = " ") -> TextEngine {
        var engine = TextEngine()
        engine.applyContext("Earlier ")
        for character in word + suffix {
            _ = engine.handle(character: character, features: features, typoSuggestion: { _ in "help" })
        }
        return engine
    }

    @Test func keyboardUndoRestoresOriginalAndDropsOnlySpace() throws {
        let engine = corrected("helo")
        let correction = try #require(engine.recentCorrection)
        #expect(correction == RecentCorrection(original: "helo", replacement: "help", suffix: " "))
        #expect(correction.undoEdit(removingSpace: true) == TextEdit(backspaces: 5, insertion: "helo"))
        #expect(correction.undoEdit(removingSpace: false) == TextEdit(backspaces: 5, insertion: "helo "))
    }

    @Test func retypingSpaceDoesNotRepeatRejectedTypo() throws {
        var engine = corrected("helo")
        let correction = try #require(engine.recentCorrection)
        engine.restore(correction, removingSpace: true)
        #expect(engine.handle(character: " ", features: features, typoSuggestion: { _ in
            Issue.record("A rejected occurrence must not be spell checked again")
            return "help"
        }) == .pass)
        #expect(engine.recentCorrection == nil)
    }

    @Test func rejectedContractionStaysRejectedBeforePeriod() throws {
        var engine = corrected("cant")
        let correction = try #require(engine.recentCorrection)
        #expect(correction.replacement == "can't")
        engine.restore(correction, removingSpace: true)
        #expect(engine.handle(character: ".", features: features) == .pass)
        #expect(engine.handle(character: " ", features: features, typoSuggestion: { _ in "can't" }) == .pass)
    }

    @Test func rejectionAppliesOnlyToThisOccurrence() throws {
        var engine = corrected("helo")
        let correction = try #require(engine.recentCorrection)
        engine.restore(correction, removingSpace: true)
        _ = engine.handle(character: " ", features: features)
        for character in "helo" { _ = engine.handle(character: character, features: features) }
        #expect(engine.handle(character: " ", features: features, typoSuggestion: { _ in "help" })
            == .edit(TextEdit(backspaces: 4, insertion: "help ")))
    }

    @Test func deferredPeriodRestoresPunctuationExactly() throws {
        let engine = corrected("helo", suffix: ". ")
        let correction = try #require(engine.recentCorrection)
        #expect(correction.undoEdit(removingSpace: true) == TextEdit(backspaces: 6, insertion: "helo."))
        #expect(correction.undoEdit(removingSpace: false) == TextEdit(backspaces: 6, insertion: "helo. "))
    }

    @Test func restoringWithSeparatorPreservesFollowingSentenceCapitalisation() throws {
        var engine = corrected("helo", suffix: ". ")
        let correction = try #require(engine.recentCorrection)
        engine.restore(correction, removingSpace: false)
        #expect(engine.handle(character: "w", features: features) == .replaceCurrentEvent(with: "W"))
    }

    @Test func restoringWithSeparatorDoesNotSuppressTheNextOccurrence() throws {
        var engine = corrected("helo")
        let correction = try #require(engine.recentCorrection)
        engine.restore(correction, removingSpace: false)
        for character in "helo" { _ = engine.handle(character: character, features: features) }
        #expect(engine.handle(character: " ", features: features, typoSuggestion: { _ in "help" })
            == .edit(TextEdit(backspaces: 4, insertion: "help ")))
    }

    @Test func returnDoesNotOfferUndoOfPossiblySentMessage() {
        let engine = corrected("helo", suffix: "\r")
        #expect(engine.recentCorrection == nil)
    }

    @Test func continuingTypingAndFocusChangesDiscardCorrection() {
        var engine = corrected("helo")
        _ = engine.handle(character: "n", features: features)
        #expect(engine.recentCorrection == nil)
        engine = corrected("helo")
        engine.invalidateContext()
        #expect(engine.recentCorrection == nil)
    }
}
