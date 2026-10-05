import XCTest
@testable import Cappy

private final class ManualDocument: CorrectionClient {
    var value: String
    var selection: NSRange
    var exposesText = true
    var reads = 0
    var onRead: ((ManualDocument) -> Void)?
    var writes = 0
    init(_ value: String, selection: NSRange? = nil) {
        self.value = value
        self.selection = selection ?? NSRange(location: (value as NSString).length, length: 0)
    }
    func selectedRange() -> NSRange { selection }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        reads += 1
        onRead?(self)
        guard exposesText, range.location != NSNotFound, NSMaxRange(range) <= (value as NSString).length else { return nil }
        return NSAttributedString(string: (value as NSString).substring(with: range))
    }
    func insertText(_ string: String, replacementRange: NSRange) {
        value = (value as NSString).replacingCharacters(in: replacementRange, with: string)
        selection = NSRange(location: replacementRange.location + (string as NSString).length, length: 0)
        writes += 1
    }
}

private final class StyledManualDocument: CorrectionClient {
    var value: NSMutableAttributedString
    var selection: NSRange
    init(_ text: NSAttributedString) {
        value = NSMutableAttributedString(attributedString: text)
        selection = NSRange(location: text.length, length: 0)
    }
    func selectedRange() -> NSRange { selection }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? { value.attributedSubstring(from: range) }
    func insertText(_ string: String, replacementRange: NSRange) { XCTFail("Rich text must use attributed insertion") }
    func insertAttributedText(_ text: NSAttributedString, replacementRange: NSRange) {
        value.replaceCharacters(in: replacementRange, with: text)
        selection = NSRange(location: replacementRange.location + text.length, length: 0)
    }
}

final class ManualCorrectionTests: XCTestCase {
    private static let frequencies = WordFrequencyModel(url: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/LanguageFrequencies.tsv"))
    private var defaultsName = ""
    private var wordsURL: URL!
    private var store: PersonalizationStore!
    private var words: ProtectedWords!
    override func setUp() {
        defaultsName = "CappyManualTests.\(UUID().uuidString)"
        store = PersonalizationStore(defaults: UserDefaults(suiteName: defaultsName)!)
        wordsURL = FileManager.default.temporaryDirectory.appendingPathComponent(defaultsName)
        words = ProtectedWords(url: wordsURL, defaultsURL: nil, watch: false)
    }
    override func tearDown() {
        store.flush()
        UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: wordsURL)
    }
    private func session() -> CorrectionSession {
        CorrectionSession(personalization: store, frequencyModel: Self.frequencies, protectedWords: words)
    }
    private func engine() -> FastCorrectionEngine {
        FastCorrectionEngine(candidateProvider: { word in
            ["teh": ["the"], "whta": ["what"]][word] ?? []
        })
    }
    func testMultipleCorrectionsAndFinalUnfinishedWord() throws {
        let result = try XCTUnwrap(ManualTextCorrection.correct("Please type teh whta", using: engine()))
        XCTAssertEqual(result.text, "Please type the what")
        XCTAssertEqual(result.count, 2)
    }
    func testExactWhitespacePunctuationAndUnicodePreserved() throws {
        let result = try XCTUnwrap(ManualTextCorrection.correct("🙂 Please\t type  teh!\nPlease whta?", using: engine()))
        XCTAssertEqual(result.text, "🙂 Please\t type  the!\nPlease what?")
    }
    func testProtectedStructuredTokensAndMediumConfidenceUntouched() throws {
        let source = "SMT CoreML /teh/whta teh.com name@whta.com 42 teh_thing"
        XCTAssertEqual(ManualTextCorrection.correct(source, using: engine())?.text, source)
        let medium = FastCorrectionEngine(candidateProvider: { _ in ["are"] })
        XCTAssertEqual(ManualTextCorrection.correct("Please ware", using: medium)?.text, "Please ware")
    }
    func testBoundAndTimeoutProduceNoPartialResult() {
        XCTAssertNil(ManualTextCorrection.correct(String(repeating: "a", count: 4097), using: engine()))
        XCTAssertNil(ManualTextCorrection.correct("teh", using: engine(), timeLimit: .zero))
    }
    func testParagraphOnlyAndExactUndo() {
        let document = ManualDocument("Earlier definately\nI definately agree.")
        let session = session()
        XCTAssertTrue(session.correctWrittenText(in: document))
        XCTAssertEqual(document.value, "Earlier definately\nI definitely agree.")
        XCTAssertEqual(document.writes, 1)
        XCTAssertTrue(session.didCommand("undo:", client: document))
        XCTAssertEqual(document.value, "Earlier definately\nI definately agree.")
        XCTAssertTrue(store.records.isEmpty, "Never persist the paragraph as a learned pair")
    }
    func testFormattingSurvivesCorrectionAndUndo() {
        let style = NSAttributedString.Key("test.style")
        let original = NSMutableAttributedString(string: "I definately agree", attributes: [style: "first"])
        let lastWord = (original.string as NSString).range(of: "agree")
        original.addAttribute(style, value: "last", range: lastWord)
        let document = StyledManualDocument(original)
        let session = session()
        XCTAssertTrue(session.correctWrittenText(in: document))
        let expected = NSMutableAttributedString(attributedString: original)
        expected.replaceCharacters(in: (original.string as NSString).range(of: "definately"), with: "definitely")
        XCTAssertTrue(document.value.isEqual(to: expected))
        XCTAssertTrue(session.didCommand("undo:", client: document))
        XCTAssertTrue(document.value.isEqual(to: original))
    }

    func testPhraseReviewReusesTheCorpusPipeline() {
        for (source, expected) in [("Ho ware you", "How are you"), ("What ar you doing", "What are you doing"), ("Can yu send it", "Can you send it")] {
            let document = ManualDocument(source)
            XCTAssertTrue(session().correctWrittenText(in: document), source)
            XCTAssertEqual(document.value, expected)
        }
    }

    func testFormattingChangeMakesBatchUndoStale() {
        let document = StyledManualDocument(NSAttributedString(string: "I definately agree"))
        let session = session()
        XCTAssertTrue(session.correctWrittenText(in: document))
        document.value.addAttribute(NSAttributedString.Key("test.style"), value: "changed", range: NSRange(location: 0, length: 2))
        XCTAssertFalse(session.didCommand("undo:", client: document))
        XCTAssertEqual(document.value.string, "I definitely agree")
    }

    func testNativeDictionaryBatch() {
        let document = ManualDocument("I typed teh whta")
        XCTAssertTrue(session().correctWrittenText(in: document))
        XCTAssertEqual(document.value, "I typed the what")
    }

    func testSelectionOnlyAndFollowingTextPreserved() {
        let document = ManualDocument("Before I definately agree after", selection: NSRange(location: 7, length: 18))
        XCTAssertTrue(session().correctWrittenText(in: document))
        XCTAssertEqual(document.value, "Before I definitely agree after")
        XCTAssertEqual(document.selection, NSRange(location: 25, length: 0))
    }
    func testMiddleCaretLeavesFollowingTextUntouched() {
        let document = ManualDocument("I definately agree after", selection: NSRange(location: 18, length: 0))
        XCTAssertTrue(session().correctWrittenText(in: document))
        XCTAssertEqual(document.value, "I definitely agree after")
        XCTAssertEqual(document.selection, NSRange(location: 18, length: 0))
    }
    func testUnavailableClientAndExcludedAppNeverWrite() {
        let document = ManualDocument("I definately agree")
        document.exposesText = false
        let session = session()
        XCTAssertFalse(session.correctWrittenText(in: document))
        document.exposesText = true
        session.correctionsSuppressedForApp = true
        XCTAssertFalse(session.correctWrittenText(in: document))
        XCTAssertEqual(document.writes, 0)
    }
    func testMovedCaretDuringAnalysisNeverWrites() {
        let document = ManualDocument("I definately agree")
        document.onRead = { doc in doc.selection = NSRange(location: 0, length: 0) }
        XCTAssertFalse(session().correctWrittenText(in: document))
        XCTAssertEqual(document.writes, 0)
    }
    func testChangedSourceBeforeWriteNeverWrites() {
        let document = ManualDocument("I definately agree")
        document.onRead = { doc in if doc.reads == 2 { doc.value = "I absolutely agree" } }
        XCTAssertFalse(session().correctWrittenText(in: document))
        XCTAssertEqual(document.writes, 0)
    }
    func testUndoRejectsChangedDocumentAndMovedCaret() {
        for moveCaret in [true, false] {
            let document = ManualDocument("I definately agree")
            let session = session()
            XCTAssertTrue(session.correctWrittenText(in: document))
            if moveCaret { document.selection = NSRange(location: 0, length: 0) }
            else { document.value = "I absolutely agree" }
            XCTAssertFalse(session.didCommand("undo:", client: document))
            XCTAssertEqual(document.writes, 1)
        }
    }
    func testProtectedWordAndNoChangeDoNotWrite() {
        XCTAssertTrue(words.protect("definately"))
        let document = ManualDocument("I definately agree")
        XCTAssertFalse(session().correctWrittenText(in: document))
        XCTAssertEqual(document.writes, 0)
    }
    func testTypingExpiresBatchUndo() {
        let document = ManualDocument("I definately agree")
        let session = session()
        XCTAssertTrue(session.correctWrittenText(in: document))
        _ = session.didCommand("moveLeft:", client: document)
        XCTAssertFalse(session.didCommand("undo:", client: document))
        XCTAssertEqual(document.writes, 1)
    }
    func testManualReviewBenchmarks() throws {
        let source = "Please type teh whta. Please type teh whta."
        _ = ManualTextCorrection.correct(source, using: engine())
        var timings: [Double] = []
        for _ in 0..<100 {
            let start = ContinuousClock.now
            let result = try XCTUnwrap(ManualTextCorrection.correct(source, using: engine()))
            XCTAssertEqual(result.count, 4)
            let elapsed = ContinuousClock.now - start
            timings.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        timings.sort()
        print("MANUAL_REVIEW_BENCHMARK deterministic 43-character passage p50_ms=\(timings[49]) p95_ms=\(timings[94])")
    }

    func testNativeReviewBenchmarks() {
        let session = session()
        let source = "I typed teh whta. I definately agree."
        XCTAssertTrue(session.correctWrittenText(in: ManualDocument(source)))
        var timings: [Double] = []
        for _ in 0..<100 {
            let document = ManualDocument(source)
            let start = ContinuousClock.now
            XCTAssertTrue(session.correctWrittenText(in: document))
            let elapsed = ContinuousClock.now - start
            XCTAssertEqual(document.value, "I typed the what. I definitely agree.")
            timings.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        timings.sort()
        print("MANUAL_REVIEW_BENCHMARK native cached \(source.count)-character passage p50_ms=\(timings[49]) p95_ms=\(timings[94])")
    }

    func testImpossibleSelectionIsRejectedBeforeReading() {
        let document = ManualDocument("I definately agree", selection: NSRange(location: Int.max - 1, length: 4))
        XCTAssertFalse(session().correctWrittenText(in: document))
        XCTAssertEqual(document.reads, 0)
        XCTAssertEqual(document.writes, 0)
    }

    func testOverlongParagraphRequiresSelection() {
        let document = ManualDocument(String(repeating: "a ", count: 2100) + "definately")
        XCTAssertFalse(session().correctWrittenText(in: document))
        XCTAssertEqual(document.writes, 0)
    }
}
