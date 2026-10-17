import AppKit
import XCTest
@testable import Cappy

private final class OverlayDocument: CorrectionClient {
    var text = ""
    var selection = NSRange(location: 0, length: 0)
    var writes = 0
    var rect: NSRect?
    var area: NSRect?
    /// A stale selection, as Electron reports while an insertion is in flight.
    var reportedSelection: NSRange?
    func selectedRange() -> NSRange { reportedSelection ?? selection }
    func caretRect() -> NSRect? { rect }
    func textRect(for range: NSRange) -> NSRect? { rect }
    func approximateAnchorRect() -> NSRect? { area }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        guard range.location != NSNotFound, NSMaxRange(range) <= (text as NSString).length else { return nil }
        return NSAttributedString(string: (text as NSString).substring(with: range))
    }
    func insertText(_ string: String, replacementRange: NSRange) {
        let range = replacementRange.location == NSNotFound ? selection : replacementRange
        text = (text as NSString).replacingCharacters(in: range, with: string)
        selection = NSRange(location: range.location + (string as NSString).length, length: 0)
        writes += 1
    }
}

final class CorrectionOverlayTests: XCTestCase {
    private let correction = FastCorrection(original: "whta", replacement: "what", suffix: " ")
    func testSharedMachineTransitionsAndRejectsOldExpiry() {
        var machine = CorrectionOverlayMachine()
        XCTAssertEqual(machine.state, .hidden)
        machine.present(.corrected(correction))
        XCTAssertEqual(machine.state, .automaticCorrection)
        XCTAssertEqual(machine.duration, 2.5)
        let old = machine.revision
        machine.present(.keep("whta"))
        XCTAssertEqual(machine.state, .undoLearning)
        XCTAssertFalse(machine.expire(revision: old))
        machine.present(.learned("whta"))
        XCTAssertEqual(machine.state, .learnedConfirmation)
        XCTAssertLessThan(machine.duration, 1)
        XCTAssertTrue(machine.expire(revision: machine.revision))
        XCTAssertEqual(machine.state, .hidden)
        machine.present(.suggestion(correction))
        XCTAssertEqual(machine.state, .suggestion)
        machine.hide()
        XCTAssertEqual(machine.state, .hidden)
    }
    func testGeometryRejectsInvalidValuesAndPlacesAboveAtBottomEdge() {
        for rect in [NSRect.zero, NSRect(x: CGFloat.nan, y: 0, width: 10, height: 20),
                     NSRect(x: 0, y: 0, width: 10, height: CGFloat.infinity),
                     NSRect(x: 0, y: 0, width: 2000, height: 20)] {
            XCTAssertFalse(CorrectionOverlayGeometry.isUsable(rect))
        }
        let screen = NSRect(x: -1000, y: 0, width: 1000, height: 800)
        let frame = CorrectionOverlayGeometry.capsuleFrame(anchor: NSRect(x: -20, y: 1, width: 10, height: 20),
            size: NSSize(width: 180, height: 28), screen: screen)
        XCTAssertTrue(screen.contains(frame)); XCTAssertEqual(frame.minY, 26)
    }
    func testEndpointGeometryRejectsCaretOnlyWrappedAndWideRects() {
        let start = NSRect(x: 100, y: 200, width: 1, height: 18)
        let end = NSRect(x: 128, y: 200, width: 1, height: 18)
        XCTAssertEqual(CorrectionOverlayGeometry.rangeRect(start: start, end: end),
            NSRect(x: 100, y: 200, width: 28, height: 18))
        XCTAssertNil(CorrectionOverlayGeometry.rangeRect(start: start, end: start))
        XCTAssertNil(CorrectionOverlayGeometry.rangeRect(start: start, end: NSRect(x: 128, y: 180, width: 1, height: 18)))
        XCTAssertNil(CorrectionOverlayGeometry.rangeRect(start: start, end: NSRect(x: 128, y: 200, width: 40, height: 18)))
    }

    func testDelayedInsertionKeepsHighlightPendingWithoutDrawingWrongText() {
        var validation = CorrectionHighlightValidation()
        XCTAssertTrue(validation.keep(age: 0, textMatches: false))
        XCTAssertFalse(validation.hasMatched)
        XCTAssertTrue(validation.keep(age: 0.12, textMatches: false))
        XCTAssertTrue(validation.keep(age: 0.24, textMatches: true))
        XCTAssertTrue(validation.hasMatched)
        XCTAssertTrue(validation.keep(age: 2.8, textMatches: true))
        XCTAssertFalse(validation.keep(age: 3, textMatches: true))
    }
    func testHighlightRejectsEditedTextAndInsertionThatNeverCompletes() {
        var validation = CorrectionHighlightValidation()
        XCTAssertTrue(validation.keep(age: 0, textMatches: true))
        // A brief stale read while later keys land keeps the highlight pending.
        XCTAssertTrue(validation.keep(age: 0.12, textMatches: false))
        XCTAssertTrue(validation.keep(age: 0.5, textMatches: true))
        XCTAssertTrue(validation.keep(age: 0.6, textMatches: false))
        XCTAssertFalse(validation.keep(age: 1.5, textMatches: false))
        var pending = CorrectionHighlightValidation()
        XCTAssertTrue(pending.keep(age: 0.9, textMatches: false))
        XCTAssertFalse(pending.keep(age: 1.01, textMatches: false))
    }
    func testRangeUsesCaretCalibrationToRemoveOneLineVerticalOffset() {
        let reported = NSRect(x: 200, y: 218, width: 0, height: 18)
        let line = NSRect(x: 200, y: 200, width: 1, height: 18)
        let word = NSRect(x: 150, y: 218, width: 45, height: 18)
        XCTAssertEqual(CorrectionOverlayGeometry.calibratedRangeRect(word, reportedCaret: reported, lineCaret: line),
            NSRect(x: 150, y: 200, width: 45, height: 18))
        // A word on a different line retains its distance from the caret.
        XCTAssertEqual(CorrectionOverlayGeometry.calibratedRangeRect(word.offsetBy(dx: 0, dy: 18),
            reportedCaret: reported, lineCaret: line), word)
    }
    func testCorrectOrUnrelatedCaretGeometryDoesNotShiftWord() {
        let caret = NSRect(x: 200, y: 200, width: 1, height: 18)
        let word = NSRect(x: 150, y: 200, width: 45, height: 18)
        XCTAssertEqual(CorrectionOverlayGeometry.calibratedRangeRect(word, reportedCaret: caret, lineCaret: caret), word)
        XCTAssertEqual(CorrectionOverlayGeometry.calibratedRangeRect(word, reportedCaret: caret, lineCaret: nil), word)
        XCTAssertEqual(CorrectionOverlayGeometry.calibratedRangeRect(word, reportedCaret: caret,
            lineCaret: caret.offsetBy(dx: 50, dy: -18)), word)
        XCTAssertEqual(CorrectionOverlayGeometry.calibratedRangeRect(word, reportedCaret: caret,
            lineCaret: caret.offsetBy(dx: 0, dy: -300)), word)
    }

    func testUnreportedBoundsAcceptWordButRejectRepeatedCaretOrPartialRange() {
        let caret = NSRect(x: 200, y: 100, width: 1, height: 20)
        let word = NSRect(x: 150, y: 100, width: 45, height: 20)
        let missing = NSRange(location: NSNotFound, length: 0)
        XCTAssertEqual(CorrectionOverlayGeometry.unreportedRangeRect(word, actual: missing, caret: caret), word)
        XCTAssertNil(CorrectionOverlayGeometry.unreportedRangeRect(caret, actual: missing, caret: caret))
        XCTAssertNil(CorrectionOverlayGeometry.unreportedRangeRect(word,
            actual: NSRange(location: 4, length: 1), caret: caret))
        XCTAssertNil(CorrectionOverlayGeometry.unreportedRangeRect(word, actual: missing, caret: word))
    }
    func testAccessibleScreenCoordinatesIncludeDisplaysAboveAndLeftOfPrimary() {
        XCTAssertEqual(AccessibleWordBounds.screenRect(CGRect(x: -300, y: -100, width: 40, height: 20), primaryScreenTop: 900),
            NSRect(x: -300, y: 980, width: 40, height: 20))
        XCTAssertNil(AccessibleWordBounds.screenRect(.zero, primaryScreenTop: 900))
        XCTAssertNil(AccessibleWordBounds.screenRect(CGRect(x: CGFloat.nan, y: 0, width: 40, height: 20), primaryScreenTop: 900))
    }

    private func withSession(_ body: (CorrectionSession, OverlayDocument, ProtectedWords) -> Void) {
        let suite = "CappyOverlay.\(UUID())"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let words = ProtectedWords(url: url, defaultsURL: nil, watch: false)
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let session = CorrectionSession(personalization: PersonalizationStore(defaults: defaults),
            frequencyModel: WordFrequencyModel(url: root.appendingPathComponent("Resources/LanguageFrequencies.tsv")), protectedWords: words)
        body(session, OverlayDocument(), words)
    }
    private func type(_ text: String, _ session: CorrectionSession, _ document: OverlayDocument) {
        for character in text { XCTAssertTrue(session.processInput(String(character), client: document)) }
    }
    func testDocumentRangesAndUndoLearningConfirmation() {
        withSession { session, doc, words in
            var states: [CorrectionOverlayState] = []
            session.onPresentation = { presentation, _ in
                var machine = CorrectionOverlayMachine(); machine.present(presentation); states.append(machine.state)
                return true
            }
            type("I typed whta ", session, doc)
            XCTAssertEqual(doc.text, "I typed what ")
            XCTAssertEqual(session.presentationAnchor?.range, NSRange(location: 8, length: 4))
            XCTAssertEqual(doc.selection, NSRange(location: 13, length: 0))
            XCTAssertTrue(session.didCommand("undo:", client: doc))
            XCTAssertEqual(doc.text, "I typed whta ")
            XCTAssertEqual(session.presentationAnchor?.text, "whta")
            XCTAssertEqual(states.last, .automaticCorrection) // first undo offers no learning action
            type("whta ", session, doc)
            XCTAssertTrue(doc.text.hasSuffix("what "))
            XCTAssertTrue(session.didCommand("undo:", client: doc))
            XCTAssertTrue(session.alwaysKeep(client: doc))
            XCTAssertEqual(states.suffix(3), [.automaticCorrection, .undoLearning, .learnedConfirmation])
            XCTAssertTrue(words.words.contains("whta"))
            type("whta ", session, doc)
            XCTAssertEqual(doc.text, "I typed whta whta whta ")
        }
    }
    func testSuggestionTypingMovementEscapeAndTabWithOverlayModel() {
        for action in ["insertTab:", "cancelOperation:", "moveLeft:", "typing"] {
            withSession { session, doc, _ in
                var machine = CorrectionOverlayMachine()
                session.onPresentation = { p, _ in machine.present(p); return true }
                session.onHide = { machine.hide() }
                type("ware you ", session, doc)
                XCTAssertEqual(machine.state, .suggestion)
                XCTAssertEqual(doc.text, "Ware you ")
                let selection = doc.selection, writes = doc.writes
                if action == "typing" { type("x", session, doc) }
                else {
                    let consumed = session.didCommand(action, client: doc)
                    XCTAssertEqual(consumed, action != "moveLeft:")
                }
                XCTAssertFalse(session.hasSuggestion)
                if action == "insertTab:" {
                    XCTAssertEqual(machine.state, .automaticCorrection)
                    XCTAssertEqual(doc.text, "Are you ")
                } else if action == "typing" {
                    XCTAssertEqual(doc.text, "Ware you x"); XCTAssertEqual(machine.state, .hidden)
                } else {
                    XCTAssertEqual(doc.selection, selection); XCTAssertEqual(doc.writes, writes)
                    XCTAssertEqual(machine.state, .hidden)
                }
            }
        }
    }
    func testTypingKeepsCorrectionPresentationWithoutRestartingItsLifetime() {
        withSession { session, doc, _ in
            var machine = CorrectionOverlayMachine()
            var tracked: CorrectionOverlayAnchor?
            session.onPresentation = { p, _ in machine.present(p); return true }
            session.onHide = { machine.hide() }
            session.onContinueTyping = { tracked = $0 }
            type("I typed whta ", session, doc)
            let revision = machine.revision
            type("next", session, doc)
            XCTAssertEqual(machine.state, .automaticCorrection)
            XCTAssertEqual(machine.revision, revision)
            XCTAssertEqual(tracked?.caret, doc.selection.location)
            XCTAssertTrue(session.undoCorrection(in: doc))
            XCTAssertEqual(doc.text, "I typed whta next")
        }
    }
    func testExpiredCapsuleCannotUndoAfterContinuedTyping() {
        withSession { session, doc, _ in
            type("I typed whta next", session, doc)
            session.expirePresentation()
            XCTAssertFalse(session.undoCorrection(in: doc))
            XCTAssertEqual(doc.text, "I typed what next")
        }
    }

    func testMissingGeometryDoesNotCaptureTabOrChangeSelection() {
        withSession { session, doc, _ in
            let overlay = CorrectionOverlayController()
            session.onPresentation = { p, client in
                let selection = client.selectedRange(), writes = doc.writes
                let shown = overlay.show(p, client: client, anchor: session.presentationAnchor, primary: {}, secondary: {})
                XCTAssertEqual(client.selectedRange(), selection); XCTAssertEqual(doc.writes, writes)
                return shown
            }
            type("ware you ", session, doc)
            XCTAssertFalse(session.hasSuggestion)
            XCTAssertEqual(overlay.machine.state, .hidden)
            XCTAssertFalse(session.didCommand("insertTab:", client: doc))
            XCTAssertEqual(doc.text, "Ware you ")
        }
    }
    func testEditorOrWindowAreaShowsFeedbackWithoutTextGeometry() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first, "Requires a display").visibleFrame
        withSession { session, doc, _ in
            doc.area = NSRect(x: screen.midX - 200, y: screen.midY - 150, width: 400, height: 300)
            let overlay = CorrectionOverlayController()
            session.onPresentation = { p, client in
                overlay.show(p, client: client, anchor: session.presentationAnchor, primary: {}, secondary: {})
            }
            type("ware you ", session, doc)
            XCTAssertTrue(session.hasSuggestion)
            XCTAssertEqual(overlay.machine.state, .suggestion)
            XCTAssertTrue(session.didCommand("insertTab:", client: doc))
            XCTAssertEqual(doc.text, "Are you ")
            overlay.hide()
        }
    }
    func testApproximatePlacementStaysInsideLargeAreasAndBesideFields() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 160, height: 24)
        let window = NSRect(x: 100, y: 100, width: 800, height: 600)
        let inside = CorrectionOverlayGeometry.approximateCapsuleFrame(area: window, size: size, screen: screen)
        XCTAssertTrue(window.contains(inside))
        XCTAssertEqual(inside.minY, 112)
        let field = NSRect(x: 300, y: 20, width: 500, height: 40)
        let beside = CorrectionOverlayGeometry.approximateCapsuleFrame(area: field, size: size, screen: screen)
        XCTAssertFalse(beside.intersects(field))
        XCTAssertTrue(screen.contains(beside))
    }
    func testCaretBelowVisibleFrameStillFindsItsScreen() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first, "Requires a display")
        let caret = NSRect(x: screen.frame.midX, y: screen.frame.minY + 1, width: 0, height: 18)
        XCTAssertEqual(CorrectionOverlayGeometry.screen(for: caret), screen)
        XCTAssertNil(CorrectionOverlayGeometry.screen(for: NSRect(x: -1e6, y: -1e6, width: 0, height: 18)))
    }
    func testLaggingHostKeepsCorrectionFeedbackWhileTyping() {
        withSession { session, doc, _ in
            var hides = 0, continued = 0
            session.onPresentation = { _, _ in true }
            session.onHide = { hides += 1 }
            session.onContinueTyping = { _ in continued += 1 }
            type("I typed whta ", session, doc)
            XCTAssertEqual(doc.text, "I typed what ")
            // Electron still reports the replaced range, then a caret behind.
            for stale in [NSRange(location: 8, length: 4), NSRange(location: 12, length: 0)] {
                hides = 0
                doc.reportedSelection = stale
                XCTAssertTrue(session.processInput("x", client: doc))
                XCTAssertEqual(hides, 0)
            }
            XCTAssertEqual(continued, 2)
            doc.reportedSelection = nil
            XCTAssertTrue(session.undoCorrection(in: doc))
            XCTAssertEqual(doc.text, "I typed whta xx")
        }
    }
    func testCaretElsewhereStillEndsCorrectionFeedback() {
        withSession { session, doc, _ in
            var hides = 0
            session.onPresentation = { _, _ in true }
            session.onHide = { hides += 1 }
            type("I typed whta ", session, doc)
            doc.selection = NSRange(location: 2, length: 0)
            XCTAssertTrue(session.processInput("x", client: doc))
            XCTAssertGreaterThan(hides, 0)
            XCTAssertFalse(session.undoCorrection(in: doc))
        }
    }
    func testPhraseHighlightCoversOnlyTheChangedWords() {
        let phrase = CorrectionOverlayAnchor(range: NSRange(location: 10, length: 15), text: "I have multiple", caret: 26)
        let changed = phrase.changedWords(from: "I have multple")
        XCTAssertEqual(changed?.text, "multiple")
        XCTAssertEqual(changed?.range, NSRange(location: 17, length: 8))
        XCTAssertEqual(changed?.caret, 26)
        let middle = CorrectionOverlayAnchor(range: NSRange(location: 0, length: 15), text: "I have a friend", caret: 16)
        XCTAssertEqual(middle.changedWords(from: "I have an friend")?.text, "a")
        let word = CorrectionOverlayAnchor(range: NSRange(location: 4, length: 4), text: "what", caret: 9)
        XCTAssertEqual(word.changedWords(from: "whta"), word)
        let split = CorrectionOverlayAnchor(range: NSRange(location: 0, length: 6), text: "a fire", caret: 7)
        XCTAssertEqual(split.changedWords(from: "afire"), split)
    }
    func testCapitalisationAndApostropheFixesDrawNoBox() {
        let im = CorrectionOverlayAnchor(range: NSRange(location: 0, length: 3), text: "I'm", caret: 4)
        XCTAssertNil(im.changedWords(from: "im"))
        let dont = CorrectionOverlayAnchor(range: NSRange(location: 0, length: 5), text: "don’t", caret: 6)
        XCTAssertNil(dont.changedWords(from: "dont"))
        let name = CorrectionOverlayAnchor(range: NSRange(location: 0, length: 5), text: "Paris", caret: 6)
        XCTAssertNil(name.changedWords(from: "paris"))
        let phrase = CorrectionOverlayAnchor(range: NSRange(location: 0, length: 12), text: "I don't know", caret: 13)
        XCTAssertNil(phrase.changedWords(from: "i dont know"))
        // A real fix still gets its box, without the cosmetic words around it.
        let mixed = CorrectionOverlayAnchor(range: NSRange(location: 0, length: 15), text: "I have multiple", caret: 16)
        XCTAssertEqual(mixed.changedWords(from: "i have multple")?.text, "multiple")
        let typo = CorrectionOverlayAnchor(range: NSRange(location: 0, length: 4), text: "what", caret: 5)
        XCTAssertEqual(typo.changedWords(from: "whta"), typo)
        XCTAssertFalse(CorrectionOverlayAnchor.isCosmetic("teh", "the"))
        XCTAssertTrue(CorrectionOverlayAnchor.isCosmetic("youre", "you're"))
    }
    func testHighlightDrawsSelectionHandlesInsideItsWindow() throws {
        let word = NSRect(x: 100, y: 200, width: 60, height: 20)
        let frame = CorrectionHighlightStyle.frame(around: word)
        let box = CorrectionHighlightStyle.box(around: word)
        XCTAssertTrue(frame.contains(box))
        let view = CorrectionHighlightStyle.makeView()
        view.frame = NSRect(origin: .zero, size: frame.size)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["CAPPY_RENDER_DIR"] {
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("highlight.png"))
        }
        func alpha(_ point: NSPoint) -> CGFloat {
            // Bitmap rows run top-down; view coordinates run bottom-up.
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            return bitmap.colorAt(x: Int(point.x * scale), y: Int((view.bounds.height - point.y) * scale))?.alphaComponent ?? 0
        }
        let local = box.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let knob = CorrectionHighlightStyle.knobDiameter
        XCTAssertGreaterThan(alpha(NSPoint(x: local.minX, y: local.maxY + knob / 2)), 0.9, "Start dot above the word")
        XCTAssertGreaterThan(alpha(NSPoint(x: local.maxX, y: local.minY - knob / 2)), 0.9, "End dot below the word")
        XCTAssertGreaterThan(alpha(NSPoint(x: local.minX, y: local.midY)), 0.9, "Start line")
        XCTAssertGreaterThan(alpha(NSPoint(x: local.maxX, y: local.midY)), 0.9, "End line")
        XCTAssertLessThan(alpha(NSPoint(x: local.midX, y: local.midY)), 0.3, "Text stays readable")
        XCTAssertEqual(alpha(NSPoint(x: local.maxX, y: local.maxY + knob / 2)), 0, "No dot above the end")
    }
    func testHostsThatNeverAnswerRangeQueriesStopBeingAsked() {
        IMKRangeSupport.reset()
        defer { IMKRangeSupport.reset() }
        for _ in 0..<IMKRangeSupport.attemptsBeforeSkipping {
            XCTAssertTrue(IMKRangeSupport.shouldQuery("electron"))
            IMKRangeSupport.record("electron", answered: false)
        }
        XCTAssertFalse(IMKRangeSupport.shouldQuery("electron"))
        IMKRangeSupport.record("native", answered: true)
        for _ in 0..<10 { IMKRangeSupport.record("native", answered: false) }
        XCTAssertTrue(IMKRangeSupport.shouldQuery("native"), "A host that has answered keeps being asked")
    }
    func testUndoNotifiesSoTheHighlightIsRemoved() {
        withSession { session, doc, _ in
            var undos = 0
            session.onPresentation = { _, _ in true }
            session.onUndo = { undos += 1 }
            type("I typed whta ", session, doc)
            XCTAssertEqual(undos, 0)
            XCTAssertTrue(session.undoCorrection(in: doc))
            XCTAssertEqual(undos, 1)
        }
    }
    func testMouseMovementBeforeAlwaysCannotLearnStaleSource() {
        withSession { session, doc, words in
            type("I typed whta ", session, doc)
            XCTAssertTrue(session.didCommand("undo:", client: doc))
            doc.selection.location = 0
            XCTAssertFalse(session.alwaysKeep(client: doc))
            XCTAssertFalse(words.words.contains("whta"))
        }
    }
}
