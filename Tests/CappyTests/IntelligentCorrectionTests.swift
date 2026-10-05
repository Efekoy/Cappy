import XCTest
@testable import Cappy

private final class LearningDocument: CorrectionClient {
    var text = ""
    var selection = NSRange(location: 0, length: 0)
    var exposesText = true
    var writes = 0
    func selectedRange() -> NSRange { selection }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        guard exposesText, range.location != NSNotFound, NSMaxRange(range) <= (text as NSString).length else { return nil }
        return NSAttributedString(string: (text as NSString).substring(with: range))
    }
    func insertText(_ string: String, replacementRange: NSRange) {
        let range = replacementRange.location == NSNotFound ? selection : replacementRange
        text = (text as NSString).replacingCharacters(in: range, with: string)
        selection = NSRange(location: range.location + (string as NSString).length, length: 0)
        writes += 1
    }
}

final class IntelligentCorrectionTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let model = WordFrequencyModel(url: root.appendingPathComponent("Resources/LanguageFrequencies.tsv"))
    private var suites: [String] = []
    private var files: [URL] = []
    private func environment() -> (CorrectionSession, PersonalizationStore, ProtectedWords, LearningDocument) {
        let suite = "CappyLearning.\(UUID())"; suites.append(suite)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suite); files.append(url)
        let words = ProtectedWords(url: url, watch: false)
        let store = PersonalizationStore(defaults: UserDefaults(suiteName: suite)!)
        return (CorrectionSession(personalization: store, frequencyModel: Self.model, protectedWords: words), store, words, LearningDocument())
    }
    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
    private func type(_ input: String, _ session: CorrectionSession, _ document: LearningDocument) {
        for character in input { XCTAssertTrue(session.processInput(String(character), client: document)) }
    }
    func testDeterministicEvaluationKeepsAutomaticPrecisionAndValidText() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/CorrectionEvaluation.json"))
        let cases = try JSONDecoder().decode([CorrectionEvaluationCase].self, from: data)
        XCTAssertGreaterThan(cases.count, 80)
        let result = CorrectionEvaluationRunner.run(cases: cases, frequencies: Self.model)
        XCTAssertEqual(result["automatic_incorrect_edits"] as? Int, 0)
        XCTAssertEqual(result["false_positive_rate"] as? Double, 0)
        XCTAssertGreaterThanOrEqual(result["automatic_recall"] as? Double ?? 0, 0.8)
        let integrity = CorrectionEvaluationRunner.integrity(cases: cases, frequencies: Self.model)
        XCTAssertEqual(integrity["undo_success"] as? Double, 1)
        XCTAssertEqual(integrity["protected_word_success"] as? Double, 1)
    }
    func testPhraseRepairsAtBoundary() {
        for (input, expected) in [("Ho ware you ", "How are you "), ("What ar you doing ", "What are you doing "), ("Can yu send it ", "Can you send it ")] {
            let (session, _, _, document) = environment()
            type(input, session, document); XCTAssertEqual(document.text, expected)
        }
    }
    func testIndependentPhraseGeneralisation() {
        let ranker = ContextualPhraseRanker(frequencies: Self.model, provider: NativeSpellingCandidates.cachedSuggestions)
        for (source, expected) in [("How ar you", "How are you"), ("What ar we", "What are we"), ("Can yu help", "Can you help")] {
            XCTAssertEqual(ranker.candidates(tokens: source.split(separator: " ").map(String.init)).first?.replacement, expected)
        }
    }
    func testBulkInputPassesThroughAndProtectedFileCommentsSurviveUIChanges() throws {
        let (session, _, words, document) = environment()
        XCTAssertTrue(session.processInput("Ho ware you ", client: document))
        XCTAssertEqual(document.text, "Ho ware you ")
        try "# Personal notes\nCappy # keep the app name\n".write(to: files.last!, atomically: true, encoding: .utf8)
        words.reload(); XCTAssertTrue(words.protect("SMT")); XCTAssertTrue(words.remove("SMT"))
        let contents = try String(contentsOf: files.last!, encoding: .utf8)
        XCTAssertTrue(contents.contains("# Personal notes"))
        XCTAssertTrue(contents.contains("Cappy # keep the app name"))
    }
    func testThresholdEdges() {
        for (value, expected) in [(0.98, CorrectionTier.automatic), (0.9799, .suggestion), (0.75, .suggestion), (0.7499, .ignore)] {
            XCTAssertEqual(CorrectionConfidence.tier(value), expected)
        }
    }
    func testStandardTranspositions() {
        let (session, _, _, document) = environment()
        type("I typed teh whta ", session, document)
        XCTAssertEqual(document.text, "I typed the what ")
    }
    func testMediumSuggestionDoesNotEditUntilTab() {
        let (session, store, _, document) = environment()
        type("ware you ", session, document)
        XCTAssertEqual(document.text, "Ware you "); XCTAssertTrue(session.hasSuggestion)
        XCTAssertTrue(session.didCommand("insertTab:", client: document))
        XCTAssertEqual(document.text, "Are you ")
        XCTAssertEqual(store.records.values.reduce(0) { $0 + $1.suggestionsAccepted }, 1)
        XCTAssertTrue(session.didCommand("undo:", client: document))
        XCTAssertEqual(document.text, "Ware you ")
    }
    func testEscapeRejectsSuggestionAndTabPassesThrough() {
        let (session, store, _, document) = environment()
        type("ware you ", session, document)
        XCTAssertTrue(session.didCommand("cancelOperation:", client: document))
        XCTAssertFalse(session.hasSuggestion)
        XCTAssertFalse(session.didCommand("insertTab:", client: document))
        XCTAssertEqual(store.records.values.reduce(0) { $0 + $1.suggestionsRejected }, 1)
        XCTAssertEqual(document.text, "Ware you ")
    }
    func testNormalTypingRecordsIgnore() {
        let (session, store, _, document) = environment()
        type("ware you x", session, document)
        XCTAssertFalse(session.hasSuggestion)
        XCTAssertEqual(document.text, "Ware you x")
        XCTAssertEqual(store.records.values.reduce(0) { $0 + $1.suggestionsIgnored }, 1)
    }
    func testSuggestionExpiryRestoresTab() {
        let (session, store, _, document) = environment()
        type("ware you ", session, document); session.expirePresentation()
        XCTAssertFalse(session.hasSuggestion)
        XCTAssertFalse(session.didCommand("insertTab:", client: document))
        XCTAssertEqual(store.records.values.reduce(0) { $0 + $1.suggestionsIgnored }, 1)
    }
    func testInvisibleSuggestionDoesNotConsumeTab() {
        let (session, _, _, document) = environment()
        session.onPresentation = { _, _ in false }
        type("ware you ", session, document)
        XCTAssertFalse(session.hasSuggestion)
        XCTAssertFalse(session.didCommand("insertTab:", client: document))
    }
    func testStaleSourceMovedCaretSelectionAndUnavailableTextBlockAcceptance() {
        for failure in 0..<4 {
            let (session, _, _, document) = environment()
            type("ware you ", session, document)
            switch failure {
            case 0: document.text = "Gone now "
            case 1: document.selection.location -= 1
            case 2: document.selection.length = 1
            default: document.exposesText = false
            }
            let before = document.text, writes = document.writes
            XCTAssertFalse(session.acceptSuggestion(in: document))
            XCTAssertEqual(document.text, before); XCTAssertEqual(document.writes, writes)
        }
    }
    func testPhraseUndoExactlyRestoresPunctuationAndUnicodeOffsets() {
        let (session, _, _, document) = environment()
        type("😀 Ho ware you? ", session, document)
        XCTAssertEqual(document.text, "😀 How are you? ")
        XCTAssertTrue(session.didCommand("deleteBackward:", client: document))
        XCTAssertEqual(document.text, "😀 Ho ware you?")
        XCTAssertEqual(document.selection.location, (document.text as NSString).length)
    }
    func testAlwaysKeepAfterUndoPersistsAndCanBeRemoved() {
        let (session, _, words, document) = environment()
        type("I typed teh ", session, document)
        XCTAssertTrue(session.didCommand("undo:", client: document))
        XCTAssertTrue(session.alwaysKeep())
        type("teh ", session, document)
        XCTAssertEqual(document.text, "I typed teh teh ")
        let relaunched = ProtectedWords(url: files.last!, watch: false)
        XCTAssertTrue(relaunched.words.contains("teh"))
        XCTAssertTrue(words.remove("teh"))
        type("teh ", session, document)
        XCTAssertTrue(document.text.hasSuffix("the "))
        XCTAssertTrue(words.protect("SMT"))
        session.invalidateSession(); document.text = ""; document.selection.location = 0
        type("SMT IFVG NQ CoreML QuantLab ", session, document)
        XCTAssertEqual(document.text, "SMT IFVG NQ CoreML QuantLab ")
    }
    func testPhraseAlwaysKeepSuppressesPairWithoutProtectingOrdinaryWords() {
        let (session, store, words, document) = environment()
        type("Ho ware you ", session, document)
        XCTAssertTrue(session.didCommand("undo:", client: document))
        XCTAssertTrue(session.alwaysKeep())
        session.invalidateSession(); document.text = ""; document.selection.location = 0
        type("Ho ware you ", session, document)
        XCTAssertEqual(document.text, "Ho ware you ")
        XCTAssertFalse(words.words.contains("you"))
        XCTAssertFalse(session.hasSuggestion)
        XCTAssertTrue(store.records.values.contains { $0.explicitlySuppressed == true })
        for key in Array(store.records.keys) { store.removeRecord(key) }
        session.invalidateSession(); document.text = ""; document.selection.location = 0
        type("Ho ware you ", session, document)
        XCTAssertEqual(document.text, "How are you ")
    }
    func testExplicitVocabularyNeverRewritesPhraseSpan() {
        let (session, _, words, document) = environment()
        XCTAssertTrue(words.protect("ware"))
        type("Ho ware you ", session, document)
        XCTAssertEqual(document.text, "Ho ware you ")
    }
    func testLearningRequiresEvidenceThenPromotesAndDemotes() {
        let (_, store, _, _) = environment()
        for _ in 0..<5 { store.record(.suggestionAccepted, original: "ware", replacement: "are") }
        XCTAssertEqual(store.adjustment(original: "ware", replacement: "are"), 0)
        for _ in 0..<7 { store.record(.suggestionAccepted, original: "ware", replacement: "are") }
        XCTAssertEqual(CorrectionConfidence.tier(0.85 + store.adjustment(original: "ware", replacement: "are")), .automatic)
        for _ in 0..<3 { store.record(.automaticUndone, original: "ware", replacement: "are") }
        XCTAssertLessThan(store.adjustment(original: "ware", replacement: "are"), 0)
    }
    func testRejectionStrongerThanIgnoredAndContextIsolated() {
        let (_, store, _, _) = environment()
        store.record(.suggestionIgnored, original: "a", replacement: "b")
        store.record(.suggestionRejected, original: "c", replacement: "d")
        XCTAssertGreaterThan(store.adjustment(original: "a", replacement: "b"), store.adjustment(original: "c", replacement: "d"))
        let context = PersonalizationStore.contextSignature(["local", "context"])
        XCTAssertFalse(context.contains("local"))
        for _ in 0..<3 { store.record(.suggestionRejected, original: "this", replacement: "that", context: context) }
        XCTAssertTrue(store.shouldSuppress(original: "this", replacement: "that", context: context))
        XCTAssertFalse(store.shouldSuppress(original: "this", replacement: "that", context: "elsewhere"))
    }
    func testLearningPersistenceAndRemovalAndMigration() {
        let (_, store, _, _) = environment()
        let defaults = UserDefaults(suiteName: suites.last!)!
        store.record(.suggestionAccepted, original: "teh", replacement: "the"); store.flush()
        let relaunched = PersonalizationStore(defaults: defaults)
        XCTAssertEqual(relaunched.records, store.records)
        relaunched.removeRecord(relaunched.records.keys.first!); relaunched.flush()
        XCTAssertTrue(PersonalizationStore(defaults: defaults).records.isEmpty)
        defaults.removeObject(forKey: "personalization.v2")
        defaults.set(["teh\u{1F}the": 3], forKey: "personalization.rejectedPairs")
        let migrated = PersonalizationStore(defaults: defaults)
        XCTAssertTrue(migrated.shouldSuppress(original: "teh", replacement: "the"))
        migrated.flush(); XCTAssertNil(defaults.object(forKey: "personalization.rejectedPairs"))
    }
    func testVocabularyRequiresRepeatedIntentionalUses() {
        let (_, store, words, _) = environment()
        XCTAssertEqual(store.vocabularyState("SMT", protectedWords: words), .unknown)
        store.observeIntentional("SMT")
        XCTAssertEqual(store.vocabularyState("SMT", protectedWords: words), .observed)
        for _ in 0..<7 { store.observeIntentional("SMT") }
        XCTAssertEqual(store.vocabularyState("SMT", protectedWords: words), .likelyIntentional)
        XCTAssertEqual(store.vocabularyState("smt", protectedWords: words), .unknown)
        for _ in 0..<10 { store.observeIntentional("bale") }
        XCTAssertEqual(store.vocabularyState("bale", protectedWords: words), .unknown)
        words.protect("SMT"); XCTAssertEqual(store.vocabularyState("smt", protectedWords: words), .protected)
        store.flush(); XCTAssertEqual(PersonalizationStore(defaults: UserDefaults(suiteName: suites.last!)!).vocabulary["SMT"], 8)
    }
    func testIncorrectSMTCorrectionUndoAlwaysKeepPreventsRecurrence() {
        let (_, store, words, document) = environment()
        let session = CorrectionSession(personalization: store, frequencyModel: Self.model, protectedWords: words,
            phraseCandidateProvider: { tokens in
                guard tokens.last == "SMT" else { return [] }
                return [CorrectionCandidate(source: "SMT", replacement: "Smart", type: "injected-error",
                    baseConfidence: 0.99, contextualConfidence: 0, evidence: "simulate a bad high-confidence hypothesis")]
            })
        type("SMT ", session, document)
        XCTAssertEqual(document.text, "Smart ")
        XCTAssertTrue(session.didCommand("deleteBackward:", client: document))
        XCTAssertEqual(document.text, "SMT")
        XCTAssertTrue(session.alwaysKeep())
        type(" SMT ", session, document)
        XCTAssertEqual(document.text, "SMT SMT ")
        XCTAssertEqual(words.words.contains("smt"), true)
    }
    func testLearnedScoresAffectRealEngineDecision() {
        let (_, store, words, document) = environment()
        let session = CorrectionSession(personalization: store, frequencyModel: Self.model, protectedWords: words)
        // Same bounded phrase/context as the engine; no preceding context.
        for _ in 0..<12 { store.record(.suggestionAccepted, original: "Ware you", replacement: "Are you") }
        type("Ware you ", session, document)
        XCTAssertEqual(document.text, "Are you ")
        XCTAssertFalse(session.hasSuggestion)
        let (otherSession, otherStore, _, otherDocument) = environment()
        otherStore.record(.automaticUndone, original: "teh", replacement: "the", context: PersonalizationStore.contextSignature(["I", "typed"]))
        type("I typed teh ", otherSession, otherDocument)
        XCTAssertEqual(otherDocument.text, "I typed teh ")
        XCTAssertTrue(otherSession.hasSuggestion)
    }
    func testOneUnfamiliarNameDoesNotProtectButRepeatedUseIsLearned() {
        let (session, store, words, document) = environment()
        type("Hello Elowen ", session, document)
        XCTAssertEqual(document.text, "Hello Elowen ")
        XCTAssertEqual(store.vocabularyState("Elowen", protectedWords: words), .observed)
        for _ in 0..<7 { type("Elowen ", session, document) }
        XCTAssertEqual(store.vocabularyState("Elowen", protectedWords: words), .likelyIntentional)
        XCTAssertFalse(words.words.contains("elowen"))
    }
    func testStoresAreBoundedAndConfidenceIsClamped() {
        let (_, store, _, _) = environment()
        for index in 0..<530 { store.record(.suggestionAccepted, original: "word\(index)", replacement: "target") }
        XCTAssertEqual(store.records.count, 512)
        for _ in 0..<30 { store.record(.suggestionAccepted, original: "a", replacement: "b") }
        XCTAssertEqual(store.adjustment(original: "a", replacement: "b"), 0.2)
        let candidate = CorrectionCandidate(source: "a", replacement: "b", type: "test", baseConfidence: 0.99, contextualConfidence: 0, personalisationAdjustment: 0.2, evidence: "test")
        XCTAssertLessThan(candidate.finalConfidence, 1)
    }
    func testPhraseGenerationIsBoundedAndLeavesUnsafeTokensUntouched() {
        let ranker = ContextualPhraseRanker(frequencies: Self.model, provider: { _ in Array(repeating: "are", count: 1000) })
        XCTAssertLessThanOrEqual(ranker.candidates(tokens: ["What", "ar", "you"]).count, 1)
        for tokens in [["SMT", "ware", "you"], ["CoreML", "ar", "you"], ["/tmp/ware", "you"], [String(repeating: "a", count: 100), "you"]] {
            XCTAssertTrue(ranker.candidates(tokens: tokens).isEmpty)
        }
    }
}
