import XCTest
import AppKit
@testable import Cappy

private final class ChromeDocument: CorrectionClient {
    var text = ""
    var caret = 0
    var exposesText = true
    var rangeUnavailable = false
    var writes = 0
    var reads = 0
    func selectedRange() -> NSRange {
        reads += 1
        return NSRange(location: rangeUnavailable ? NSNotFound : caret, length: 0)
    }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        reads += 1
        guard exposesText, range.location != NSNotFound, NSMaxRange(range) <= (text as NSString).length else { return nil }
        return NSAttributedString(string: (text as NSString).substring(with: range))
    }
    func insertText(_ string: String, replacementRange: NSRange) {
        let range = replacementRange.location == NSNotFound ? NSRange(location: caret, length: 0) : replacementRange
        text = (text as NSString).replacingCharacters(in: range, with: string)
        caret = range.location + (string as NSString).length
        writes += 1
    }
    func hostTypes(_ string: String) {
        // Native Chromium inserts the original event after Cappy returns false.
        text = (text as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: string)
        caret += (string as NSString).length
    }
}

final class ChromeTypingTests: XCTestCase {
    private static let frequencies = WordFrequencyModel(url: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/LanguageFrequencies.tsv"))
    private var store: PersonalizationStore!
    private var words: ProtectedWords!
    private var suite: String!
    private var wordsURL: URL!
    override func setUp() {
        suite = "ChromeTypingTests.\(UUID().uuidString)"
        store = PersonalizationStore(defaults: UserDefaults(suiteName: suite)!)
        wordsURL = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        words = ProtectedWords(url: wordsURL, defaultsURL: nil, watch: false)
    }
    override func tearDown() {
        store.flush()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: wordsURL)
    }
    private func session() -> CorrectionSession {
        let session = CorrectionSession(personalization: store, frequencyModel: Self.frequencies, protectedWords: words)
        session.usesNativeTyping = true
        return session
    }
    private func type(_ string: String, through session: CorrectionSession, into document: ChromeDocument) {
        for character in string {
            let event = String(character)
            XCTAssertFalse(session.processNativeInput(event, client: document), "Original key must reach Chrome")
            document.hostTypes(event)
        }
    }
    func testChromePolicyIncludesReleaseChannelsWithoutMatchingUnrelatedApps() {
        for id in ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary"] {
            XCTAssertTrue(InputClientPolicy.usesNativeTyping(bundleIdentifier: id))
        }
        for id in [nil, "com.apple.TextEdit", "com.google.ChromeFake", "com.apple.Safari"] {
            XCTAssertFalse(InputClientPolicy.usesNativeTyping(bundleIdentifier: id))
        }
    }
    func testOrdinaryCharactersNeverReadOrWriteThroughIMK() {
        let document = ChromeDocument()
        type("hello🙂", through: session(), into: document)
        XCTAssertEqual(document.text, "hello🙂")
        XCTAssertEqual(document.reads, 0)
        XCTAssertEqual(document.writes, 0)
    }
    func testSpaceCorrectsCommittedWordButNeverInsertsTheNativeSeparator() {
        let document = ChromeDocument()
        type("I typed teh ", through: session(), into: document)
        XCTAssertEqual(document.text, "I typed the ")
        XCTAssertEqual(document.writes, 1)
        XCTAssertEqual(document.caret, (document.text as NSString).length)
    }
    func testUnavailableDocumentStillTypesEveryCharacterOnce() {
        for unavailableRange in [false, true] {
            let document = ChromeDocument()
            document.exposesText = false
            document.rangeUnavailable = unavailableRange
            type("i typed teh 🙂 ", through: session(), into: document)
            XCTAssertEqual(document.text, "i typed teh 🙂 ")
            XCTAssertEqual(document.writes, 0)
        }
    }
    func testSpaceCommandIsForwardedWithoutDoubleInsertion() {
        let document = ChromeDocument()
        let session = session()
        type("i", through: session, into: document)
        XCTAssertFalse(session.didCommand("insertSpace:", client: document))
        document.hostTypes(" ")
        XCTAssertEqual(document.text, "I ")
        XCTAssertEqual(document.writes, 1)
    }
    func testImmediateBackspaceUndoRestoresOriginalLowercaseI() {
        let document = ChromeDocument()
        let session = session()
        type("i ", through: session, into: document)
        XCTAssertTrue(session.didCommand("deleteBackward:", client: document))
        XCTAssertEqual(document.text, "i")
        XCTAssertEqual(document.caret, 1)
    }
    func testPronounCapitalizesAtStartAndInsideSentence() {
        let document = ChromeDocument()
        type("i think i can ", through: session(), into: document)
        XCTAssertEqual(document.text, "I think I can ")
    }
    func testPassiveIgnoredCaseSuggestionsDoNotDisableEnglishPronounRule() {
        let context = PersonalizationStore.contextSignature(["I", "think"])
        for _ in 0..<20 { store.record(.suggestionIgnored, original: "i", replacement: "I", context: context) }
        let document = ChromeDocument()
        type("i think i can ", through: session(), into: document)
        XCTAssertEqual(document.text, "I think I can ")
        XCTAssertLessThan(store.adjustment(original: "i", replacement: "I", context: context), 0)
    }
    func testExplicitlyProtectedIStillRemainsUntouched() {
        XCTAssertTrue(words.protect("i"))
        let document = ChromeDocument()
        type("i think i can ", through: session(), into: document)
        XCTAssertEqual(document.text, "i think i can ")
    }
    func testExplicitRejectionStillLowersPronounConfidence() {
        for _ in 0..<3 { store.record(.automaticUndone, original: "i", replacement: "I") }
        let document = ChromeDocument()
        type("i think i can ", through: session(), into: document)
        XCTAssertEqual(document.text, "i think i can ")
    }
    func testNativeReturnTabPasteAndPunctuationNeverGetReinserted() {
        let document = ChromeDocument()
        let session = session()
        for event in ["\n", "\t", "pasted sentence", "!"] {
            XCTAssertFalse(session.processNativeInput(event, client: document))
            document.hostTypes(event)
        }
        XCTAssertEqual(document.text, "\n\tpasted sentence!")
        XCTAssertEqual(document.reads, 0)
        XCTAssertEqual(document.writes, 0)
    }
    func testManualReviewRemainsAvailableWithNativeTyping() {
        let document = ChromeDocument()
        let session = session()
        type("I typed definately", through: session, into: document)
        XCTAssertTrue(session.correctWrittenText(in: document))
        XCTAssertEqual(document.text, "I typed definitely")
    }
    private func key(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code)!
    }
    func testControllerOverridesTheRawIMKEventSelector() {
        XCTAssertTrue(CappyInputController.instancesRespond(to: NSSelectorFromString("handleEvent:client:")))
    }
    func testExcludedClientsReceiveNativeEventsWithoutDocumentCalls() {
        let document = ChromeDocument()
        let session = session()
        session.correctionsSuppressedForApp = true
        var router = CorrectionEventRouter()
        XCTAssertFalse(router.handle(key("a", code: 0), session: session, client: document))
        XCTAssertEqual(document.reads, 0)
        XCTAssertEqual(document.writes, 0)
    }
    func testDirectChromeEventsForwardLettersBeforeAnyClientRead() {
        let document = ChromeDocument()
        let session = session()
        var router = CorrectionEventRouter()
        XCTAssertFalse(router.handle(key("i", code: 34), session: session, client: document))
        XCTAssertEqual(document.reads, 0)
        XCTAssertEqual(document.writes, 0)
        document.hostTypes("i")
        XCTAssertFalse(router.handle(key(" ", code: 49), session: session, client: document))
        document.hostTypes(" ")
        XCTAssertEqual(document.text, "I ")
    }
    func testDirectNativeTextViewRetainsTypingCorrectionAndBackspaceUndo() {
        let document = ChromeDocument()
        let session = session()
        session.usesNativeTyping = false
        var router = CorrectionEventRouter()
        XCTAssertTrue(router.handle(key("i", code: 34), session: session, client: document))
        XCTAssertTrue(router.handle(key(" ", code: 49), session: session, client: document))
        XCTAssertEqual(document.text, "I ")
        XCTAssertTrue(router.handle(key("\u{7f}", code: 51), session: session, client: document))
        XCTAssertEqual(document.text, "i")
    }
    func testDirectCommandUndoRestoresCorrection() {
        let document = ChromeDocument()
        let session = session()
        type("i ", through: session, into: document)
        var router = CorrectionEventRouter()
        XCTAssertTrue(router.handle(key("z", code: 6, modifiers: .command), session: session, client: document))
        XCTAssertEqual(document.text, "i ")
    }
    func testDirectShortcutsReturnNavigationAndFunctionKeysAreForwarded() {
        for event in [key("t", code: 17, modifiers: .command), key("a", code: 0, modifiers: .control),
                      key("\r", code: 36), key("\t", code: 48), key("\t", code: 48, modifiers: .shift),
                      key("\u{F702}", code: 123), key("\u{F704}", code: 122)] {
            let document = ChromeDocument()
            var router = CorrectionEventRouter()
            XCTAssertFalse(router.handle(event, session: session(), client: document))
            XCTAssertEqual(document.writes, 0)
        }
    }
    func testOptionAndCompositionContinuationAreNotInsertedByCappy() {
        let document = ChromeDocument()
        let session = session()
        session.usesNativeTyping = false
        var router = CorrectionEventRouter()
        XCTAssertFalse(router.handle(key("´", code: 14, modifiers: .option), session: session, client: document))
        XCTAssertFalse(router.handle(key("é", code: 14), session: session, client: document))
        document.hostTypes("é")
        XCTAssertEqual(document.reads, 0)
        XCTAssertEqual(document.writes, 0)
        XCTAssertTrue(router.handle(key("x", code: 7), session: session, client: document))
        XCTAssertEqual(document.text, "éx")
    }
    func testRouterResetDoesNotLeakCompositionStateBetweenClients() {
        let document = ChromeDocument()
        let session = session()
        session.usesNativeTyping = false
        var router = CorrectionEventRouter()
        XCTAssertFalse(router.handle(key("´", code: 14, modifiers: .option), session: session, client: document))
        router.reset()
        XCTAssertTrue(router.handle(key("x", code: 7), session: session, client: document))
        XCTAssertEqual(document.text, "x")
    }
    func testDirectTabAcceptsVisibleSuggestionButDoesNotInsertATab() {
        let document = ChromeDocument()
        document.hostTypes("I used ")
        let session = CorrectionSession(personalization: store, frequencyModel: Self.frequencies, protectedWords: words,
            phraseCandidateProvider: { tokens in
                guard tokens.last == "ware" else { return [] }
                return [CorrectionCandidate(source: "ware", replacement: "are", type: "test", baseConfidence: 0.8,
                    contextualConfidence: 0, evidence: "test")]
            })
        session.onPresentation = { _, _ in true }
        var router = CorrectionEventRouter()
        for character in "ware " {
            XCTAssertTrue(router.handle(key(String(character), code: 0), session: session, client: document))
        }
        XCTAssertTrue(session.hasSuggestion)
        XCTAssertTrue(router.handle(key("\t", code: 48), session: session, client: document))
        XCTAssertEqual(document.text, "I used are ")
    }

    func testPronounRuleDoesNotNeedSurroundingContext() {
        var engine = FastCorrectionEngine(candidateProvider: { _ in [] })
        engine.synchronize(leftContext: nil)
        XCTAssertEqual(engine.consume("i ")?.replacement, "I")
    }
}
