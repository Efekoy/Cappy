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

    func testUnknownContextAvoidsCapitalisation() {
        var engine = FastCorrectionEngine()
        engine.synchronize(leftContext: nil)
        _ = engine.consume("hello")
        XCTAssertNil(engine.consume(" "))
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
