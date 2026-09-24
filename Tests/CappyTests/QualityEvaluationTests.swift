import XCTest
@testable import Cappy

final class QualityEvaluationTests: XCTestCase {
    func testHighConfidenceContextCorpus() {
        let cases: [(String, String)] = [
            ("Your going home ", "You're going home"),
            ("Your doing great ", "You're doing great"),
            ("Their going to ", "They're going to"),
            ("There going home ", "They're going home"),
            ("Its going away ", "It's going away"),
            ("I left there car ", "their car"),
            ("That is there phone ", "their phone"),
            ("I should of ", "should have"),
            ("I could of ", "could have"),
            ("I would of ", "would have")
        ]

        for (input, expectedReplacement) in cases {
            XCTAssertEqual(lastCorrection(in: input)?.replacement, expectedReplacement, input)
        }
    }

    func testValidPhraseCorpusDoesNotChange() {
        let cases = [
            "Your car ",
            "Your house ",
            "Their car ",
            "Their phone ",
            "There is ",
            "There was ",
            "Its name ",
            "Its colour ",
            "Your ready meal ",
            "Their going rate ",
            "Its going rate ",
            "I should offer "
        ]

        for input in cases {
            XCTAssertNil(lastCorrection(in: input), input)
        }
    }

    func testProtectedTokenCorpusDoesNotChange() {
        let cases = [
            "https://example.com/aggree ",
            "efe@example.com ",
            "/tmp/aggree ",
            "snake_case ",
            "ReflectIQ ",
            "550e8400-e29b-41d4-a716-446655440000 ",
            "v1.2.3 "
        ]

        for input in cases {
            XCTAssertNil(lastCorrection(in: input), input)
        }
    }

    func testDeterministicP95IsBelowOneMillisecond() {
        var samples: [UInt64] = []
        samples.reserveCapacity(2_000)

        for _ in 0..<2_000 {
            var engine = FastCorrectionEngine()
            let start = DispatchTime.now().uptimeNanoseconds
            _ = engine.consume("Your ")
            _ = engine.consume("going ")
            _ = engine.consume("home ")
            samples.append(DispatchTime.now().uptimeNanoseconds - start)
        }

        samples.sort()
        let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
        XCTAssertLessThan(p95, 1_000_000, "deterministic p95 was \(p95 / 1_000) µs")
    }

    private func lastCorrection(in input: String) -> FastCorrection? {
        var engine = FastCorrectionEngine()
        engine.synchronize(leftContext: "")
        var last: FastCorrection?
        for character in input {
            if let correction = engine.consume(String(character)) {
                last = correction
            }
        }
        return last
    }
}
