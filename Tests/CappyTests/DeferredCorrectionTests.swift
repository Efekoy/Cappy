import XCTest
@testable import Cappy

/// Drives deferred work by hand: lookups finish and time passes only when a test says so.
private final class ManualScheduler: CorrectionScheduler {
    var now: TimeInterval = 0
    var cached: Set<String> = []
    private var lookups: [(String, () -> Void)] = []
    private var action: (() -> Void)?
    private var fireTime: TimeInterval = .infinity
    var requestedLookups: [String] = []

    func isCached(_ word: String) -> Bool { cached.contains(word) }
    func lookUp(_ word: String, completion: @escaping () -> Void) {
        requestedLookups.append(word)
        lookups.append((word, completion))
    }
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        self.action = action
        fireTime = now + delay
    }
    func finishLookups() {
        let pending = lookups
        lookups = []
        for (word, completion) in pending { cached.insert(word); completion() }
    }
    func advance(_ seconds: TimeInterval) {
        now += seconds
        for _ in 0..<32 {
            guard let action, fireTime <= now else { return }
            self.action = nil
            action()
        }
    }
}

/// Cappy inserts typed text itself, as in Electron apps.
private final class Document: CorrectionClient {
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

/// Chrome inserts forwarded keys itself and can answer queries before they land.
private final class LaggingNativeDocument: CorrectionClient {
    var text = ""
    var caret = 0
    var queued: [String] = []
    func settle() {
        for key in queued { insertText(key, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        queued = []
    }
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

final class DeferredCorrectionTests: XCTestCase {
    private static let frequencies = WordFrequencyModel(url: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/LanguageFrequencies.tsv"))
    private var suites: [String] = []
    private var files: [URL] = []

    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        for url in files { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    private func makeSession() -> (CorrectionSession, ManualScheduler) {
        let name = "CappyDeferredTests.\(UUID().uuidString)"
        suites.append(name)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".txt")
        files.append(url)
        let session = CorrectionSession(personalization: PersonalizationStore(defaults: UserDefaults(suiteName: name)!),
            frequencyModel: Self.frequencies, protectedWords: ProtectedWords(url: url, defaultsURL: nil, watch: false))
        let scheduler = ManualScheduler()
        session.scheduler = scheduler
        return (session, scheduler)
    }

    private func type(_ text: String, _ session: CorrectionSession, _ document: Document) {
        for character in text { XCTAssertTrue(session.processInput(String(character), client: document)) }
    }

    private func typeNative(_ text: String, _ session: CorrectionSession, _ document: LaggingNativeDocument) {
        for character in text {
            let key = String(character)
            XCTAssertFalse(session.processNativeInput(key, client: document))
            document.queued.append(key)
        }
    }

    func testUncachedSpaceNeverWaitsAndCorrectsAtThePause() {
        let (session, scheduler) = makeSession()
        let document = Document()
        type("I definately agree ", session, document)
        // Every space passed straight through; lookups run in the background.
        XCTAssertEqual(document.text, "I definately agree ")
        XCTAssertTrue(scheduler.requestedLookups.contains("definately"))
        scheduler.finishLookups()
        scheduler.advance(0.2)
        XCTAssertEqual(document.text, "I definitely agree ")
        XCTAssertEqual(document.caret, (document.text as NSString).length)
        XCTAssertFalse(session.hasDeferredCorrections)
    }

    func testCachedWordsStillCorrectImmediately() {
        let (session, scheduler) = makeSession()
        scheduler.cached = ["dont"]
        _ = NativeSpellingCandidates.suggestions(for: "dont")
        let document = Document()
        type("dont ", session, document)
        XCTAssertEqual(document.text, "Don't ")
        XCTAssertFalse(session.hasDeferredCorrections)
    }

    func testDeferredCorrectionWaitsForAPauseInTyping() {
        let (session, scheduler) = makeSession()
        let document = Document()
        type("welocme ", session, document)
        scheduler.finishLookups()
        scheduler.advance(0.05)
        type("b", session, document)
        scheduler.advance(0.05)
        XCTAssertEqual(document.text, "welocme b", "No edit while keys are still arriving")
        type("ack", session, document)
        scheduler.advance(0.2)
        XCTAssertEqual(document.text, "Welcome back")
        XCTAssertEqual(document.caret, (document.text as NSString).length)
    }

    func testLaggingHostStillCapitalisesAtTheSentenceStart() {
        let (session, scheduler) = makeSession()
        let document = LaggingNativeDocument()
        document.text = "Hello. "; document.caret = 7
        // The host answers every query before these keys land.
        typeNative("i think this ", session, document)
        XCTAssertEqual(document.text, "Hello. ")
        document.settle()
        scheduler.finishLookups()
        scheduler.advance(0.2)
        scheduler.finishLookups()
        scheduler.advance(0.2)
        XCTAssertEqual(document.text, "Hello. I think this ")
        XCTAssertEqual(document.caret, (document.text as NSString).length)
    }

    func testLaggingHostCapitalisesFirstWordOfSentence() {
        let (session, scheduler) = makeSession()
        let document = LaggingNativeDocument()
        document.text = "Done. "; document.caret = 6
        typeNative("thanks ", session, document)
        document.settle()
        scheduler.finishLookups()
        scheduler.advance(0.2)
        scheduler.finishLookups()
        scheduler.advance(0.2)
        XCTAssertEqual(document.text, "Done. Thanks ")
    }

    func testNavigationDropsPendingCorrection() {
        let (session, scheduler) = makeSession()
        let document = Document()
        type("definately ", session, document)
        XCTAssertFalse(session.didCommand("moveLeft:", client: document))
        scheduler.finishLookups()
        scheduler.advance(0.2)
        XCTAssertEqual(document.text, "definately ")
    }

    func testEnterDropsPendingCorrection() {
        let (session, scheduler) = makeSession()
        let document = Document()
        type("definately ", session, document)
        XCTAssertFalse(session.didCommand("insertNewline:", client: document))
        scheduler.finishLookups()
        scheduler.advance(0.2)
        XCTAssertEqual(document.text, "definately ")
    }

    func testBackspaceRestoresDeferredCorrection() {
        let (session, scheduler) = makeSession()
        let document = Document()
        type("definately ", session, document)
        scheduler.finishLookups()
        scheduler.advance(0.2)
        XCTAssertEqual(document.text, "Definitely ")
        XCTAssertTrue(session.didCommand("deleteBackward:", client: document))
        XCTAssertEqual(document.text, "definately")
    }

    func testBackspacingOverTheSpaceDropsPendingCorrection() {
        let (session, scheduler) = makeSession()
        let document = Document()
        type("definately ", session, document)
        // The host deletes the space; Cappy only observes the command.
        XCTAssertFalse(session.didCommand("deleteBackward:", client: document))
        document.insertText("", replacementRange: NSRange(location: document.caret - 1, length: 1))
        type("s", session, document)
        scheduler.finishLookups()
        scheduler.advance(0.2)
        XCTAssertEqual(document.text, "definatelys")
    }

    func testEditedWordIsNotReplaced() {
        let (session, scheduler) = makeSession()
        let document = Document()
        type("definately agree", session, document)
        // Something else rewrote the pending word before the pause.
        document.text = "defiantly agree"; document.caret = (document.text as NSString).length
        scheduler.finishLookups()
        scheduler.advance(1)
        XCTAssertEqual(document.text, "defiantly agree")
    }
}
