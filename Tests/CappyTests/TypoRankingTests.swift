import XCTest
@testable import Cappy

private final class PlainDocument: CorrectionClient {
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

/// Typos reported from real use that the dictionary alone could not settle.
final class TypoRankingTests: XCTestCase {
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

    private func makeSession() -> (CorrectionSession, PersonalizationStore) {
        let name = "CappyTypoRankingTests.\(UUID().uuidString)"
        suites.append(name)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".txt")
        files.append(url)
        let store = PersonalizationStore(defaults: UserDefaults(suiteName: name)!)
        let session = CorrectionSession(personalization: store, frequencyModel: Self.frequencies,
            protectedWords: ProtectedWords(url: url, defaultsURL: nil, watch: false))
        // The fuzzy corpus fallback is installed asynchronously on the spelling queue.
        _ = NativeSpellingCandidates.suggestions(for: "cappy")
        return (session, store)
    }

    private func typed(_ text: String) -> String {
        let (session, _) = makeSession()
        let document = PlainDocument()
        for character in text { XCTAssertTrue(session.processInput(String(character), client: document)) }
        return document.text
    }

    func testFarTypoWithoutDictionaryGuessesAndContextualShortTypo() {
        XCTAssertEqual(typed("I defitnetaly agre with this "), "I definitely agree with this ")
    }

    func testFrequencyBreaksTieAndContractionGetsApostrophe() {
        XCTAssertEqual(typed("Ok I tiink so thanks for that now I understand thats the best "),
                       "Ok I think so thanks for that now I understand that's the best ")
    }

    func testCommonHardTypos() {
        XCTAssertEqual(typed("we did it becuase it was acutally somthing different "),
                       "We did it because it was actually something different ")
    }

    func testAmbiguousShortTypoWithoutContextIsLeftAlone() {
        let ranker = SpellingRanker(frequencies: Self.frequencies) { _ in ["are", "agree", "age", "acre"] }
        XCTAssertNil(ranker.rank(previous: nil, word: "agre", next: nil))
        XCTAssertEqual(ranker.rank(previous: nil, word: "agre", next: "with")?.replacement, "agree")
    }

    func testFrequencyAloneSettlesLongerWords() {
        let ranker = SpellingRanker(frequencies: Self.frequencies) { _ in ["think", "twink", "tink", "Tina"] }
        XCTAssertEqual(ranker.rank(previous: nil, word: "tiink", next: nil)?.replacement, "think")
    }

    func testCloseCompetitorsAreNotGuessed() {
        let ranker = SpellingRanker(frequencies: Self.frequencies) { _ in ["cleaners", "cancers", "crackers"] }
        XCTAssertNil(ranker.rank(previous: nil, word: "clankers", next: nil))
    }

    func testCommonWordsAreNeverReplaced() {
        let ranker = SpellingRanker(frequencies: Self.frequencies) { _ in ["think"] }
        XCTAssertNil(ranker.rank(previous: nil, word: "thing", next: nil))
    }

    func testCommonSlips() {
        XCTAssertTrue(SpellingRanker.isCommonSlip("agre", "agree"))
        XCTAssertTrue(SpellingRanker.isCommonSlip("tommorrow", "tomorrow"))
        XCTAssertTrue(SpellingRanker.isCommonSlip("teh", "the"))
        XCTAssertTrue(SpellingRanker.isCommonSlip("thibk", "think"))
        XCTAssertFalse(SpellingRanker.isCommonSlip("agre", "are"))
        XCTAssertFalse(SpellingRanker.isCommonSlip("tiink", "think"))
    }

    func testFuzzySearchFindsOnlyCloseCommonWords() {
        XCTAssertEqual(Self.frequencies.closeWords(to: "defitnetaly").first, "definitely")
        XCTAssertTrue(Self.frequencies.closeWords(to: "xqzrplk").isEmpty)
    }

    func testUndoneWordIsNotRevisitedByTheNextWord() {
        let (session, store) = makeSession()
        store.recordRejected(original: "agre", replacement: "agree")
        let document = PlainDocument()
        for character in "I agre with this " { XCTAssertTrue(session.processInput(String(character), client: document)) }
        XCTAssertEqual(document.text, "I agre with this ")
    }

    func testContractionsThatAreAlsoWordsStay() {
        XCTAssertEqual(typed("we were well "), "We were well ")
    }
}
