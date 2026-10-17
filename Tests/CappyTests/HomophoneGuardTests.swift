import CoreML
import XCTest
@testable import Cappy

private final class HomophoneDocument: CorrectionClient {
    var text = ""
    var caret = 0
    func selectedRange() -> NSRange { NSRange(location: caret, length: 0) }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        guard range.location != NSNotFound, NSMaxRange(range) <= (text as NSString).length else { return nil }
        return NSAttributedString(string: (text as NSString).substring(with: range))
    }
    func insertText(_ string: String, replacementRange: NSRange) {
        let range = replacementRange.location == NSNotFound ? NSRange(location: caret, length: 0) : replacementRange
        text = (text as NSString).replacingCharacters(in: range, with: string)
        caret = range.location + (string as NSString).length
    }
}

/// Valid homophones reported changed in real use. The bundled classifier rates
/// existential “there is/are/was/were” as thereToTheir at 0.96–0.99 depending
/// on the words before it, so its confidence alone must never swap them.
final class HomophoneGuardTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let frequencies = WordFrequencyModel(url: root.appendingPathComponent("Resources/LanguageFrequencies.tsv"))
    private static let corpusEvidence: FastCorrectionEngine.HomophoneEvidenceProvider = {
        HomophoneGuard.evidence(left: $0, source: $1, replacement: $2, frequencies: frequencies)
    }
    /// The shipped Core ML reranker, compiled from Resources at test time.
    private static let reranker: ContextReranker? = {
        guard let compiled = try? MLModel.compileModel(at: root.appendingPathComponent("Resources/ContextReranker.mlmodel")) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CappyReranker.\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: compiled, to: directory.appendingPathComponent("ContextReranker.mlmodelc"))
        guard let bundle = Bundle(url: directory) else { return nil }
        let reranker = ContextReranker(bundle: bundle, computeUnits: .cpuOnly)
        return reranker.isAvailable ? reranker : nil
    }()
    private var suites: [String] = []
    private var files: [URL] = []

    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        for url in files { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    /// Types `text` through a full session with the real reranker and returns
    /// the document and every correction or suggestion it presented.
    private func typed(_ text: String) throws -> (text: String, presented: [FastCorrection]) {
        let reranker = try XCTUnwrap(Self.reranker, "the bundled Core ML reranker must compile")
        let name = "CappyHomophoneGuardTests.\(UUID().uuidString)"
        suites.append(name)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".txt")
        files.append(url)
        let session = CorrectionSession(personalization: PersonalizationStore(defaults: UserDefaults(suiteName: name)!),
            frequencyModel: Self.frequencies, protectedWords: ProtectedWords(url: url, defaultsURL: nil, watch: false),
            rerankProvider: reranker.decision)
        var presented: [FastCorrection] = []
        session.onPresentation = { presentation, _ in
            switch presentation {
            case .corrected(let correction), .suggestion(let correction): presented.append(correction)
            case .keep, .learned: break
            }
            return true
        }
        let document = HomophoneDocument()
        for character in text { XCTAssertTrue(session.processInput(String(character), client: document)) }
        return (document.text, presented)
    }

    private func engine(rerank: ContextualAction? = nil, phrase: CorrectionCandidate? = nil,
                        personal: Double = 0, evidence: FastCorrectionEngine.HomophoneEvidenceProvider? = corpusEvidence) -> FastCorrectionEngine {
        FastCorrectionEngine(
            rerankProvider: rerank.map { action in { _ in ContextualRerankDecision(action: action, confidence: 0.999) } },
            phraseProvider: phrase.map { candidate in { tokens in
                tokens.joined(separator: " ").hasSuffix(candidate.source) ? [candidate] : []
            } },
            personalScore: { _ in personal },
            homophoneEvidence: evidence
        )
    }

    private func phrase(_ source: String, _ replacement: String) -> CorrectionCandidate {
        CorrectionCandidate(source: source, replacement: replacement, type: "phrase",
            baseConfidence: 0.75, contextualConfidence: 0.24, evidence: "test")
    }

    /// Corrections that change words, not just sentence-start capitalisation.
    private func edits(_ corrections: [FastCorrection]) -> [FastCorrection] {
        corrections.filter { $0.original.lowercased() != $0.replacement.lowercased() }
    }

    /// Feeds `text` and returns the automatic corrections and suggestions.
    private func run(_ text: String, through engine: inout FastCorrectionEngine) -> (automatic: [FastCorrection], suggestions: [FastCorrection]) {
        engine.synchronize(leftContext: "")
        var automatic: [FastCorrection] = [], suggestions: [FastCorrection] = []
        for character in text {
            if let correction = engine.consume(String(character)) { automatic.append(correction) }
            if let suggestion = engine.suggestion { suggestions.append(suggestion) }
        }
        return (automatic, suggestions)
    }

    func testReportedSentenceKeepsExistentialThere() throws {
        let result = try typed("when there is one blue box and another pops up ")
        XCTAssertEqual(result.text, "When there is one blue box and another pops up ")
        XCTAssertFalse(result.presented.contains { $0.replacement.lowercased().contains("their") }, "\(result.presented)")
    }

    func testExistentialThereSurvivesContextsTheClassifierRatesAboveThreshold() throws {
        for sentence in [
            "I think there is a problem ", "only when there is one left ", "because there are two of them ",
            "so there was one more ", "I think there were many ", "it breaks when there is no space "
        ] {
            let result = try typed(sentence)
            XCTAssertEqual(result.text.lowercased(), sentence.lowercased(), sentence)
            XCTAssertFalse(result.presented.contains { $0.replacement.lowercased().contains("their") }, sentence)
        }
    }

    func testClassifierAloneCannotSwapThereEvenAtFullConfidence() {
        var classifier = engine(rerank: .thereToTheir)
        let result = run("when there is one blue box ", through: &classifier)
        XCTAssertEqual(edits(result.automatic), [])
        // The corpus contradicts “their is”, so it is not even offered.
        XCTAssertEqual(result.suggestions, [])
    }

    func testCorpusCorroboratedThereToTheirStaysAutomatic() {
        var classifier = engine(rerank: .thereToTheir)
        let result = run("I like there new car ", through: &classifier)
        XCTAssertEqual(result.automatic.last?.replacement, "their new")
    }

    func testUncorroboratedContractionIsOnlyASuggestion() {
        // The corpus cannot score “you're”, so the classifier's word is not enough.
        for evidence in [Self.corpusEvidence, nil] {
            var classifier = engine(rerank: .yourToYoure, evidence: evidence)
            let result = run("Your returning tomorrow ", through: &classifier)
            XCTAssertEqual(edits(result.automatic), [])
            XCTAssertEqual(result.suggestions.last?.replacement, "You're returning tomorrow")
        }
    }

    func testToTooAndThenThanNeedExactContext() {
        var valid = engine(phrase: phrase("and then you", "and than you"))
        XCTAssertEqual(edits(run("We left and then you ", through: &valid).automatic), [])
        XCTAssertEqual(run("We left and then you ", through: &valid).suggestions, [])

        var validTo = engine(phrase: phrase("want to go", "want too go"))
        XCTAssertEqual(edits(run("we want to go ", through: &validTo).automatic), [])
        XCTAssertEqual(run("we want to go ", through: &validTo).suggestions, [])

        var mistake = engine(phrase: phrase("more then you", "more than you"))
        XCTAssertEqual(run("I like it more then you ", through: &mistake).automatic.last?.replacement, "more than you")
    }

    func testPersonalLearningCannotPromoteAHomophoneSwap() {
        var learned = engine(phrase: CorrectionCandidate(source: "its going", replacement: "it's going", type: "phrase",
            baseConfidence: 0.75, contextualConfidence: 0.11, evidence: "test"), personal: 0.2)
        let result = run("I think its going ", through: &learned)
        XCTAssertEqual(edits(result.automatic), [])
        XCTAssertEqual(result.suggestions.last?.replacement, "it's going")
    }

    func testCuratedPatternsStillCorrectButSkipExistentialQuestions() throws {
        XCTAssertEqual(try typed("I left there car ").text, "I left their car ")
        XCTAssertEqual(try typed("Your going home ").text, "You're going home ")
        XCTAssertEqual(try typed("That is there phone ").text, "That is their phone ")
        for sentence in ["Is there room for me ", "Was there work today ", "Is there going to be food ", "So why is there room "] {
            XCTAssertEqual(try typed(sentence).text, sentence)
        }
    }

    func testSwapDetectionIgnoresTyposAndCaseOnlyChanges() {
        XCTAssertEqual(HomophoneGuard.swappedIndices(source: ["there", "is"], replacement: ["their", "is"]), [0])
        XCTAssertEqual(HomophoneGuard.swappedIndices(source: ["Its", "going"], replacement: ["It’s", "going"]), [0])
        XCTAssertNil(HomophoneGuard.swappedIndices(source: ["teh"], replacement: ["the"]))
        XCTAssertNil(HomophoneGuard.swappedIndices(source: ["there"], replacement: ["There"]))
        XCTAssertNil(HomophoneGuard.swappedIndices(source: ["there", "si"], replacement: ["their", "is"]))
    }
}
