import XCTest
import AppKit
@testable import Cappy

final class CrossAppSupportTests: XCTestCase {
    func testFindsWordByContentNearestTheExpectedDistance() {
        // "the" ends 4 units before the caret (" now"); an earlier "the" is farther.
        let window = "the cat saw the now"
        XCTAssertEqual(AccessibleWordMatch.distances(in: window, caretOffset: 19, word: "the", expected: 4), [4])
        XCTAssertEqual(AccessibleWordMatch.distances(in: window, caretOffset: 19, word: "the", expected: 4, tolerance: 20), [4, 16])
    }

    func testToleratesAHostThatLagsACharacterOrTwo() {
        // The accessibility tree has not received the final typed "w" yet.
        XCTAssertEqual(AccessibleWordMatch.distances(in: "said the no", caretOffset: 11, word: "the", expected: 4), [3])
    }

    func testMatchesWholeWordsOnly() {
        XCTAssertEqual(AccessibleWordMatch.distances(in: "there then the", caretOffset: 14, word: "the", expected: 0), [0])
        XCTAssertTrue(AccessibleWordMatch.distances(in: "other ", caretOffset: 6, word: "the", expected: 2).isEmpty)
        XCTAssertTrue(AccessibleWordMatch.distances(in: "don't", caretOffset: 5, word: "don", expected: 2).isEmpty)
    }

    func testMatchesPhrasesAndHandlesCaretInsideWindow() {
        XCTAssertEqual(AccessibleWordMatch.distances(in: "I have multiple ap", caretOffset: 16, word: "have multiple", expected: 1), [1])
        XCTAssertTrue(AccessibleWordMatch.distances(in: "abc", caretOffset: 9, word: "a", expected: 0).isEmpty)
        XCTAssertTrue(AccessibleWordMatch.distances(in: "abc", caretOffset: 3, word: "", expected: 0).isEmpty)
    }

    func testRejectsEmptyAndWholeEditorBounds() {
        let editor = CGRect(x: 48, y: 759, width: 518, height: 37)
        XCTAssertTrue(AccessibleWordMatch.isTextBounds(CGRect(x: 120, y: 765, width: 30, height: 20), editorFrame: editor))
        XCTAssertFalse(AccessibleWordMatch.isTextBounds(editor, editorFrame: editor), "Chrome's answer without layout")
        XCTAssertFalse(AccessibleWordMatch.isTextBounds(CGRect(x: 0, y: 956, width: 0, height: 0), editorFrame: editor))
        XCTAssertFalse(AccessibleWordMatch.isTextBounds(CGRect(x: CGFloat.nan, y: 0, width: 30, height: 20), editorFrame: nil))
    }

    func testTypingActivityReportsPauses() {
        TypingActivity.noteKey(at: 100)
        XCTAssertFalse(TypingActivity.isQuiet(for: 0.08, now: 100.05))
        XCTAssertTrue(TypingActivity.isQuiet(for: 0.08, now: 100.1))
        TypingActivity.noteKey(at: -.infinity)
    }

    func testCancelledLookupReportsCancellation() {
        let lookup = WordBoundsLookup()
        XCTAssertFalse(lookup.isCancelled)
        lookup.cancel()
        XCTAssertTrue(lookup.isCancelled)
    }
}
