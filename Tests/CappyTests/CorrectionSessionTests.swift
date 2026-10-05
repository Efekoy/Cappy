import XCTest
@testable import Cappy

/// Models native text views: explicit replacements leave the caret at the end
/// of the replacement, and immediate post-write range queries can be stale.
private final class TestDocument: CorrectionClient {
    var text = ""
    var caret = 0
    var staleRange: NSRange?
    var delaysCaretQueries = false
    var exposesText = true
    var writes = 0

    func selectedRange() -> NSRange { staleRange ?? NSRange(location: caret, length: 0) }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        guard exposesText, range.location != NSNotFound, NSMaxRange(range) <= (text as NSString).length else { return nil }
        return NSAttributedString(string: (text as NSString).substring(with: range))
    }
    func insertText(_ string: String, replacementRange: NSRange) {
        let prior = NSRange(location: caret, length: 0)
        let range = replacementRange.location == NSNotFound ? prior : replacementRange
        text = (text as NSString).replacingCharacters(in: range, with: string)
        caret = range.location + (string as NSString).length
        writes += 1
        if delaysCaretQueries { staleRange = prior }
    }
    func nextEvent() { staleRange = nil }
}

final class CorrectionSessionTests: XCTestCase {
    private static let frequencyModel = WordFrequencyModel(url: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/LanguageFrequencies.tsv"))
    private var suites: [String] = []
    private var wordFiles: [URL] = []
    private func makeSession(protectedWords: ProtectedWords? = nil) -> CorrectionSession {
        let name = "CappySessionTests.\(UUID().uuidString)"
        suites.append(name)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".txt")
        wordFiles.append(url)
        let vocabulary = protectedWords ?? ProtectedWords(url: url, defaultsURL: nil, watch: false)
        return CorrectionSession(personalization: PersonalizationStore(defaults: UserDefaults(suiteName: name)!), frequencyModel: Self.frequencyModel, protectedWords: vocabulary)
    }
    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        for url in wordFiles { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    private func type(_ text: String, through session: CorrectionSession, into document: TestDocument) {
        for character in text {
            document.nextEvent()
            XCTAssertTrue(session.processInput(String(character), client: document))
        }
        document.nextEvent()
    }

    func testCorrectionKeepsCaretAfterSpaceAndFollowingText() {
        let session = makeSession()
        let document = TestDocument()
        type("I definately agree ", through: session, into: document)
        XCTAssertEqual(document.text, "I definitely agree ")
        XCTAssertEqual(document.caret, (document.text as NSString).length)
        XCTAssertEqual(document.writes, "I definately agree ".count)
    }

    func testDelayedPostInsertionCaretDoesNotLoseWordBuffer() {
        let session = makeSession()
        let document = TestDocument()
        document.delaysCaretQueries = true
        type("hello dont worry ", through: session, into: document)
        XCTAssertEqual(document.text, "Hello don't worry ")
    }

    func testSpaceCommandCommitsCorrection() {
        let session = makeSession()
        let document = TestDocument()
        type("dont", through: session, into: document)
        XCTAssertTrue(session.didCommand("insertSpace:", client: document))
        XCTAssertEqual(document.text, "Don't ")
    }

    func testReturnPassesThroughWithoutChangingMessage() {
        for command in ["insertNewline:", "insertNewlineIgnoringFieldEditor:", "insertLineBreak:", "insertParagraphSeparator:"] {
            let session = makeSession()
            let document = TestDocument()
            type("dont", through: session, into: document)
            let writes = document.writes
            XCTAssertFalse(session.didCommand(command, client: document))
            XCTAssertEqual(document.text, "dont")
            XCTAssertEqual(document.caret, 4)
            XCTAssertEqual(document.writes, writes)
        }
    }

    func testNewlineTextDoesNotCorrectLastWord() {
        for newline in ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"] {
            let session = makeSession()
            let document = TestDocument()
            type("dont", through: session, into: document)
            XCTAssertTrue(session.processInput(newline, client: document))
            XCTAssertEqual(document.text, "dont" + newline)
            type("I dont ", through: session, into: document)
            XCTAssertEqual(document.text, "dont" + newline + "I don't ")
        }
    }

    func testTabCorrectsWithoutInsertingSeparatorOrSwallowingCommand() {
        for command in ["insertTab:", "insertBacktab:"] {
            let session = makeSession()
            let document = TestDocument()
            type("dont", through: session, into: document)
            XCTAssertFalse(session.didCommand(command, client: document))
            XCTAssertEqual(document.text, "Don't")
            XCTAssertEqual(document.caret, 5)
        }
    }

    func testBackspaceAndUndoRestoreOriginalAtRealCaret() {
        for (command, expected) in [("deleteBackward:", "I definately"), ("undo:", "I definately ")] {
            let session = makeSession()
            let document = TestDocument()
            type("I definately ", through: session, into: document)
            XCTAssertTrue(session.didCommand(command, client: document))
            XCTAssertEqual(document.text, expected)
        }
    }

    func testUnavailableTextPassesThroughWithoutUnsafeReplacement() {
        let session = makeSession()
        let document = TestDocument()
        document.exposesText = false
        type("I definately ", through: session, into: document)
        XCTAssertEqual(document.text, "I definately ")
    }

    func testMovedCaretCannotReplaceBufferedWordElsewhere() {
        let session = makeSession()
        let document = TestDocument()
        type("I definately", through: session, into: document)
        document.caret = 1
        XCTAssertTrue(session.processInput(" ", client: document))
        XCTAssertEqual(document.text, "I  definately")
    }

    func testScreenshotTypos() {
        let session = makeSession()
        let document = TestDocument()
        type("Test 123 test tests come on nwo thta this becaues ", through: session, into: document)
        XCTAssertEqual(document.text, "Test 123 test tests come on now that this because ")
    }
    func testGeneralDictionaryCorrectionWithoutTypoTable() {
        let session = makeSession()
        let document = TestDocument()
        type("Hello whta is yuor name? This is what its doign. ", through: session, into: document)
        XCTAssertEqual(document.text, "Hello what is your name? This is what its doing. ")
    }

    func testFrequencyModelFixesValidWordTypoWithTwoSidedContext() {
        XCTAssertTrue(Self.frequencyModel.isAvailable)
        let session = makeSession()
        let document = TestDocument()
        type("it should be bale to do all corrections ", through: session, into: document)
        XCTAssertEqual(document.text, "It should be able to do all corrections ")
    }

    func testFrequencyModelGeneralisesToAnotherRealWordTransposition() {
        let session = makeSession()
        let document = TestDocument()
        type("I heard form you yesterday ", through: session, into: document)
        XCTAssertEqual(document.text, "I heard from you yesterday ")
    }

    func testFrequencyModelKeepsValidRareWordAndPossessivePhrases() {
        for input in ["I have a bale of hay ", "Their going rate is fair ", "Your ready meal is here ", "The ship will sail to port ", "The form you need is here ", "We will discuss the trial tomorrow ", "She walked along the trail yesterday "] {
            let session = makeSession()
            let document = TestDocument()
            type(input, through: session, into: document)
            XCTAssertEqual(document.text, input)
        }
    }

    func testPunctuationCorrectionPreservesPunctuationWhenReverted() {
        let session = makeSession()
        let document = TestDocument()
        type("is it whta? ", through: session, into: document)
        XCTAssertEqual(document.text, "Is it what? ")
        XCTAssertTrue(session.didCommand("deleteBackward:", client: document))
        XCTAssertEqual(document.text, "Is it whta?")
    }

    func testDictionaryCorrectionKeepsDomainAndEmailIntact() {
        let session = makeSession()
        let document = TestDocument()
        type("visit whta.com and yuor@example.com ", through: session, into: document)
        XCTAssertEqual(document.text, "Visit whta.com and yuor@example.com ")
    }

    func testRestoresMissingApostrophesWithoutContractionTable() {
        let session = makeSession()
        let document = TestDocument()
        type("we shouldnt wouldnt couldnt hadnt isnt arent shant ", through: session, into: document)
        XCTAssertEqual(document.text, "We shouldn't wouldn't couldn't hadn't isn't aren't shan't ")
    }

    func testReportedShouldntTypoPreservesLettersAndCase() {
        for (input, expected) in [
            ("shouldnt ", "Shouldn't "),
            ("Shouldnt ", "Shouldn't "),
            ("I shouldnt do this ", "I shouldn't do this "),
            ("I shouldnt? ", "I shouldn't? "),
            ("I shouldn't do this ", "I shouldn't do this "),
            ("I shouldn’t do this ", "I shouldn’t do this ")
        ] {
            let session = makeSession()
            let document = TestDocument()
            type(input, through: session, into: document)
            XCTAssertEqual(document.text, expected)
        }
    }

    func testProtectedVocabularyPreventsSpellingCapitalisationAndContextEdits() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CappyProtected-\(UUID()).txt")
        wordFiles.append(url)
        try "# Words to preserve\ncappy\nyuor # intentional spelling\nbale\n".write(to: url, atomically: true, encoding: .utf8)
        let protected = ProtectedWords(url: url, defaultsURL: nil, watch: false)
        let session = makeSession(protectedWords: protected)
        let document = TestDocument()
        type("cappy says yuor name shouldnt change. It should be bale to ", through: session, into: document)
        XCTAssertEqual(document.text, "cappy says yuor name shouldn't change. It should be bale to ")
    }

    func testSavingProtectedWordFileUpdatesRunningSession() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CappyWatch-\(UUID()).txt")
        wordFiles.append(url)
        try "Cappy\n".write(to: url, atomically: true, encoding: .utf8)
        let protected = ProtectedWords(url: url, defaultsURL: nil, watch: true)
        let session = makeSession(protectedWords: protected)
        try "Cappy\nyuor\n".write(to: url, atomically: true, encoding: .utf8)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in protected.words.contains("yuor") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)
        let document = TestDocument()
        type("Hello yuor friend ", through: session, into: document)
        XCTAssertEqual(document.text, "Hello yuor friend ")
    }

}
