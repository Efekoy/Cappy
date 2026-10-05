import XCTest
@testable import Cappy

final class FastCorrectionEngineTests: XCTestCase {
    func testCorrectsRequestedTypoAfterSpace() {
        var engine = FastCorrectionEngine()
        for character in "I definately" { XCTAssertNil(engine.consume(String(character))) }
        XCTAssertEqual(engine.consume(" "), FastCorrection(
            original: "definately",
            replacement: "definitely",
            suffix: " "
        ))
    }

    func testPreservesInitialCapitalisation() {
        var engine = FastCorrectionEngine()
        _ = engine.consume("Definately")
        XCTAssertEqual(engine.consume("\n")?.replacement, "Definitely")
    }

    func testCorrectsTypoShownInUserReport() {
        var engine = FastCorrectionEngine()
        engine.synchronize(leftContext: "Hello chat ")
        _ = engine.consume("welocme")
        XCTAssertEqual(engine.consume(" ")?.replacement, "welcome")
    }

    func testCorrectsGenericDuplicateLetterTypo() {
        var engine = FastCorrectionEngine(candidateProvider: { word in
            word == "commmittee" ? ["committee"] : []
        })
        engine.synchronize(leftContext: "I ")
        _ = engine.consume("commmittee")
        XCTAssertEqual(engine.consume(" ")?.replacement, "committee")
    }

    func testCorrectsTopRankedMissingSpaceIncludingContraction() {
        var contraction = FastCorrectionEngine(candidateProvider: { word in
            word == "can'tget" ? ["can't get", "can't-get"] : []
        })
        contraction.synchronize(leftContext: "")
        _ = contraction.consume("Can'tget")
        XCTAssertEqual(contraction.consume(" "), FastCorrection(
            original: "Can'tget",
            replacement: "Can't get",
            suffix: " "
        ))

        var ordinary = FastCorrectionEngine(candidateProvider: { word in
            word == "whatabout" ? ["what about", "what-about"] : []
        })
        ordinary.synchronize(leftContext: "Tell me ")
        _ = ordinary.consume("whatabout")
        XCTAssertEqual(ordinary.consume(" ")?.replacement, "what about")
    }

    func testDoesNotPreferLowerRankedSplitOverDictionaryRecommendation() {
        var lowerRanked = FastCorrectionEngine(candidateProvider: { word in
            word == "inthe" ? ["into", "in the"] : []
        })
        lowerRanked.synchronize(leftContext: "Meet me ")
        _ = lowerRanked.consume("inthe")
        XCTAssertEqual(lowerRanked.consume(" ")?.replacement, "into")

        var inexact = FastCorrectionEngine(candidateProvider: { _ in ["can get"] })
        inexact.synchronize(leftContext: "I ")
        _ = inexact.consume("can'tget")
        XCTAssertNil(inexact.consume(" "))
    }

    func testNativeDictionaryRanksAgreeForReportedTypo() {
        XCTAssertEqual(NativeSpellingCandidates.suggestions(for: "aggree").first, "agree")
    }

    func testNativeDictionaryRestoresShouldntWithoutChangingLetters() {
        XCTAssertEqual(NativeSpellingCandidates.suggestions(for: "shouldnt").first, "shouldn't")
        var engine = FastCorrectionEngine()
        engine.synchronize(leftContext: "I ")
        _ = engine.consume("shouldnt")
        XCTAssertEqual(engine.consume(" "), FastCorrection(
            original: "shouldnt", replacement: "shouldn't", suffix: " "
        ))
    }

    func testNativeDictionaryRanksRequestedMissingSpaceFirst() {
        XCTAssertEqual(NativeSpellingCandidates.suggestions(for: "can'tget").first, "can't get")
        var engine = FastCorrectionEngine(candidateProvider: NativeSpellingCandidates.suggestions)
        engine.synchronize(leftContext: "")
        _ = engine.consume("Can'tget")
        XCTAssertEqual(engine.consume(" ")?.replacement, "Can't get")
    }

    func testCorrectsGeneratedTranspositionAndMissingLetter() {
        var engine = FastCorrectionEngine(candidateProvider: { word in
            switch word {
            case "watre": return ["water", "ware"]
            case "agre": return ["agree"]
            default: return []
            }
        })
        engine.synchronize(leftContext: "Some ")
        _ = engine.consume("watre")
        XCTAssertEqual(engine.consume(" ")?.replacement, "water")

        _ = engine.consume("agre")
        XCTAssertEqual(engine.consume(" ")?.replacement, "agree")
    }

    func testCorrectsGeneratedKeyboardNeighbourSubstitution() {
        var engine = FastCorrectionEngine(candidateProvider: { $0 == "hellp" ? ["hello"] : [] })
        engine.synchronize(leftContext: "Say ")
        _ = engine.consume("hellp")
        XCTAssertEqual(engine.consume(" ")?.replacement, "hello")
    }

    func testRejectsDistantDictionarySuggestion() {
        var distant = FastCorrectionEngine(candidateProvider: { _ in ["different"] })
        distant.synchronize(leftContext: "A ")
        _ = distant.consume("xyzword")
        XCTAssertNil(distant.consume(" "))
    }

    func testDoesNotDictionaryCorrectIdentifiersWithMixedCase() {
        var engine = FastCorrectionEngine(candidateProvider: { _ in ["reflect"] })
        engine.synchronize(leftContext: "Use ")
        _ = engine.consume("ReflectIQ")
        XCTAssertNil(engine.consume(" "))
    }

    func testCapitalisesFirstWordInEmptyDocument() {
        var engine = FastCorrectionEngine()
        engine.synchronize(leftContext: "")
        _ = engine.consume("hello")
        XCTAssertEqual(engine.consume(" ")?.replacement, "Hello")
    }

    func testCapitalisesAfterSentenceTerminator() {
        var engine = FastCorrectionEngine()
        engine.synchronize(leftContext: "That worked. ")
        _ = engine.consume("next")
        XCTAssertEqual(engine.consume(" ")?.replacement, "Next")
    }

    func testDoesNotCapitaliseInMiddleOfSentence() {
        var engine = FastCorrectionEngine()
        engine.synchronize(leftContext: "Hello ")
        _ = engine.consume("chat")
        XCTAssertNil(engine.consume(" "))
    }

    func testAddsHighConfidenceApostrophes() {
        var engine = FastCorrectionEngine()
        engine.synchronize(leftContext: "")
        _ = engine.consume("dont")
        XCTAssertEqual(engine.consume(" ")?.replacement, "Don't")

        engine.synchronize(leftContext: "I ")
        _ = engine.consume("dont")
        XCTAssertEqual(engine.consume(" ")?.replacement, "don't")
    }

    func testContextCorrectsYourGoing() {
        var engine = FastCorrectionEngine()
        engine.synchronize(leftContext: "")
        XCTAssertNil(engine.consume("Your "))
        XCTAssertNil(engine.consume("going "))
        XCTAssertEqual(engine.consume("home "), FastCorrection(
            original: "Your going home",
            replacement: "You're going home",
            suffix: " "
        ))
    }

    func testContextCorrectsThereCarAndShouldOf() {
        var engine = FastCorrectionEngine()
        engine.synchronize(leftContext: "I left ")
        XCTAssertNil(engine.consume("there "))
        XCTAssertEqual(engine.consume("car ")?.replacement, "their car")

        engine.synchronize(leftContext: "I should ")
        XCTAssertEqual(engine.consume("of ")?.replacement, "should have")
    }

    func testContextCorrectsTheirThereAndItsBeforePredicate() {
        for (source, expected) in [
            ("Their going to ", "They're going to"),
            ("There going home ", "They're going home"),
            ("Its going away ", "It's going away")
        ] {
            var engine = FastCorrectionEngine()
            engine.synchronize(leftContext: "")
            let words = source.split(separator: " ").map(String.init)
            XCTAssertNil(engine.consume(words[0] + " "))
            XCTAssertNil(engine.consume(words[1] + " "))
            XCTAssertEqual(engine.consume(words[2] + " ")?.replacement, expected)
        }
    }

    func testContextKeepsValidPossessivesAndExistentialThere() {
        for source in ["Your car ", "Their car ", "There is ", "Its name "] {
            var engine = FastCorrectionEngine()
            engine.synchronize(leftContext: "")
            let words = source.split(separator: " ").map(String.init)
            XCTAssertNil(engine.consume(words[0] + " "))
            XCTAssertNil(engine.consume(words[1] + " "))
        }

        for source in ["Your ready meal ", "Their going rate ", "Its going rate "] {
            var engine = FastCorrectionEngine()
            engine.synchronize(leftContext: "")
            for word in source.split(separator: " ") {
                XCTAssertNil(engine.consume(word + " "), source)
            }
        }
    }

    func testPersonalSuppressionPreventsRepeatedCorrection() {
        var engine = FastCorrectionEngine(suppressionProvider: { original, replacement in
            original == "Your going home" && replacement == "You're going home"
        })
        engine.synchronize(leftContext: "")
        _ = engine.consume("Your ")
        _ = engine.consume("going ")
        XCTAssertNil(engine.consume("home "))
    }

    func testUnknownContextAvoidsCapitalisation() {
        var engine = FastCorrectionEngine()
        engine.synchronize(leftContext: nil)
        _ = engine.consume("hello")
        XCTAssertNil(engine.consume(" "))
    }

    func testNeuralRerankerAppliesOnlyValidatedHighConfidenceAction() {
        var engine = FastCorrectionEngine(rerankProvider: { _ in
            ContextualRerankDecision(action: .yourToYoure, confidence: 0.999)
        })
        engine.synchronize(leftContext: "")
        XCTAssertNil(engine.consume("Your "))
        XCTAssertNil(engine.consume("returning "))
        XCTAssertEqual(engine.consume("tomorrow ")?.replacement, "You're returning tomorrow")

        var mismatched = FastCorrectionEngine(rerankProvider: { _ in
            ContextualRerankDecision(action: .thereToTheir, confidence: 0.999)
        })
        mismatched.synchronize(leftContext: "")
        XCTAssertNil(mismatched.consume("Your returning tomorrow "))
    }

    func testNeuralRerankerKeepsLowConfidenceText() {
        var engine = FastCorrectionEngine(rerankProvider: { _ in
            ContextualRerankDecision(action: .yourToYoure, confidence: 0.94)
        })
        engine.synchronize(leftContext: "")
        XCTAssertNil(engine.consume("Your returning tomorrow "))
    }

    func testDoesNotCorrectURLsPathsOrInsideLongTokens() {
        var engine = FastCorrectionEngine()
        _ = engine.consume("definately.com ")
        XCTAssertNil(engine.consume("next "))

        engine.invalidate()
        XCTAssertNil(engine.consume("/tmp/definately "))

        engine.invalidate()
        XCTAssertNil(engine.consume("name@definately "))

        engine.invalidate()
        _ = engine.consume(String(repeating: "a", count: FastCorrectionEngine.maximumWordLength + 1) + "definately")
        XCTAssertNil(engine.consume(" "))
    }

    func testSupportsUnicodeWithoutSplittingGraphemes() {
        var engine = FastCorrectionEngine()
        for character in "naïve definately " {
            if character == " " && engine.currentWord == "definately" {
                XCTAssertEqual(engine.consume(String(character))?.replacement, "definitely")
            } else {
                _ = engine.consume(String(character))
            }
        }
    }

    func testInvalidationDropsBufferedWordAndAdvancesGeneration() {
        var engine = FastCorrectionEngine()
        _ = engine.consume("defin")
        let priorGeneration = engine.generation
        engine.invalidate()
        XCTAssertTrue(engine.currentWord.isEmpty)
        XCTAssertEqual(engine.generation, priorGeneration + 1)
        _ = engine.consume("ately ")
        XCTAssertTrue(engine.currentWord.isEmpty)
    }

    func testRangesUseUTF16DocumentOffsets() {
        let correction = FastCorrection(original: "definately", replacement: "definitely", suffix: " ")
        XCTAssertEqual(correction.originalUTF16Length, 10)
        XCTAssertEqual(correction.replacementUTF16Length, 10)
        XCTAssertEqual(correction.suffixUTF16Length, 1)
    }

    func testReplacementRangeLeavesCommittedSpaceInPlace() {
        let correction = FastCorrection(original: "definately", replacement: "definitely", suffix: " ")
        let sourceRange = CorrectionRangePlanner.sourceRange(
            for: correction,
            selection: NSRange(location: 13, length: 0)
        )
        XCTAssertEqual(sourceRange, NSRange(location: 2, length: 10))
        XCTAssertEqual(
            CorrectionRangePlanner.undoRange(for: correction, sourceRange: sourceRange!),
            NSRange(location: 2, length: 11)
        )
    }

    func testReplacementRangeRejectsSelectionsAndImpossibleOffsets() {
        let correction = FastCorrection(original: "definately", replacement: "definitely", suffix: " ")
        XCTAssertNil(CorrectionRangePlanner.sourceRange(
            for: correction,
            selection: NSRange(location: 13, length: 2)
        ))
        XCTAssertNil(CorrectionRangePlanner.sourceRange(
            for: correction,
            selection: NSRange(location: 5, length: 0)
        ))
    }
}

final class PersonalizationStoreTests: XCTestCase {
    func testTwoImmediateRejectionsSuppressPairWithoutStoringContext() {
        let suiteName = "CappyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PersonalizationStore(defaults: defaults)

        XCTAssertFalse(store.shouldSuppress(original: "aggree", replacement: "agree"))
        store.recordRejected(original: "aggree", replacement: "agree")
        XCTAssertFalse(store.shouldSuppress(original: "aggree", replacement: "agree"))
        store.recordRejected(original: "aggree", replacement: "agree")
        XCTAssertTrue(store.shouldSuppress(original: "aggree", replacement: "agree"))
        store.recordAccepted(original: "aggree", replacement: "agree")
        store.recordAccepted(original: "aggree", replacement: "agree")
        XCTAssertFalse(store.shouldSuppress(original: "aggree", replacement: "agree"))
    }
}
