import AppKit
import InputMethodKit

private struct CorrectionLedger {
    let generation: UInt64
    let range: NSRange
    let original: String
    let correctedText: String
    let suffix: String
    let expectedCaretLocation: Int
}

@objc(CappyInputController)
final class CappyInputController: IMKInputController {
    private var engine = FastCorrectionEngine(candidateProvider: NativeSpellingCandidates.suggestions)
    private var recentCorrection: CorrectionLedger?
    private var expectedCaretLocation: Int?
    private var needsContextSync = true

    override func activateServer(_ sender: Any!) {
        invalidateSession()
        super.activateServer(sender)
    }

    override func deactivateServer(_ sender: Any!) {
        invalidateSession()
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        invalidateSession()
    }

    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        guard let string, !string.isEmpty, let client = sender as? any IMKTextInput else { return false }
        return processInput(string, client: client)
    }

    private func processInput(_ string: String, client: any IMKTextInput) -> Bool {
        let inputReceived = ContinuousClock.now

        reconcileCaret(with: client)
        synchronizeContextIfNeeded(from: client)
        recentCorrection = nil

        // Direct input is committed before any correction work. The deterministic
        // Phase 1 decision is then measured and applied as one minimal replacement.
        client.insertText(string, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        let correction = engine.consume(string)
        PerformanceRecorder.shared.recordFastDecision(startedAt: inputReceived)

        guard let correction else {
            rememberCaret(from: client)
            return true
        }

        apply(correction, to: client, inputReceived: inputReceived)
        return true
    }

    override func didCommand(by aSelector: Selector!, client sender: Any!) -> Bool {
        guard let client = sender as? any IMKTextInput else {
            invalidateSession()
            return false
        }

        let command = NSStringFromSelector(aSelector)
        if command == "deleteBackward:", restoreRecentCorrection(in: client, removingSuffix: true) {
            return true
        }
        if command == "undo:", restoreRecentCorrection(in: client, removingSuffix: false) {
            return true
        }

        invalidateSession()
        return false
    }

    private func apply(
        _ correction: FastCorrection,
        to client: any IMKTextInput,
        inputReceived: ContinuousClock.Instant
    ) {
        let selection = client.selectedRange()
        guard let sourceRange = CorrectionRangePlanner.sourceRange(for: correction, selection: selection) else {
            invalidateSession()
            return
        }
        guard text(in: sourceRange, from: client) == correction.original else {
            invalidateSession()
            return
        }

        client.insertText(correction.replacement, replacementRange: sourceRange)
        PerformanceRecorder.shared.recordReplacement(startedAt: inputReceived)
        let expectedCaret = sourceRange.location + correction.replacementUTF16Length + correction.suffixUTF16Length
        recentCorrection = CorrectionLedger(
            generation: engine.generation,
            range: CorrectionRangePlanner.undoRange(for: correction, sourceRange: sourceRange),
            original: correction.original,
            correctedText: correction.replacement + correction.suffix,
            suffix: correction.suffix,
            expectedCaretLocation: expectedCaret
        )
        expectedCaretLocation = expectedCaret
    }

    private func restoreRecentCorrection(in client: any IMKTextInput, removingSuffix: Bool) -> Bool {
        guard let correction = recentCorrection,
              correction.generation == engine.generation else { return false }
        let selection = client.selectedRange()
        guard selection.location == correction.expectedCaretLocation,
              selection.length == 0,
              text(in: correction.range, from: client) == correction.correctedText else {
            invalidateSession()
            return false
        }

        let restored = correction.original + (removingSuffix ? "" : correction.suffix)
        client.insertText(restored, replacementRange: correction.range)
        invalidateSession()
        expectedCaretLocation = correction.range.location + (restored as NSString).length
        return true
    }

    private func reconcileCaret(with client: any IMKTextInput) {
        guard let expectedCaretLocation else { return }
        let current = client.selectedRange()
        if current.location != NSNotFound,
           (current.location != expectedCaretLocation || current.length != 0) {
            invalidateSession()
        }
    }

    private func rememberCaret(from client: any IMKTextInput) {
        let selection = client.selectedRange()
        expectedCaretLocation = selection.location == NSNotFound || selection.length != 0 ? nil : selection.location
    }

    private func synchronizeContextIfNeeded(from client: any IMKTextInput) {
        guard needsContextSync else { return }
        needsContextSync = false

        let selection = client.selectedRange()
        guard selection.location != NSNotFound, selection.length == 0 else {
            engine.synchronize(leftContext: nil)
            return
        }

        let length = min(selection.location, FastCorrectionEngine.maximumContextUTF16Length)
        let range = NSRange(location: selection.location - length, length: length)
        if length == 0 {
            engine.synchronize(leftContext: "")
        } else {
            engine.synchronize(leftContext: text(in: range, from: client))
        }
    }

    private func text(in range: NSRange, from client: any IMKTextInput) -> String? {
        guard range.location != NSNotFound,
              let attributed = client.attributedSubstring(from: range),
              attributed.length == range.length else { return nil }
        return attributed.string
    }

    private func invalidateSession() {
        engine.invalidate()
        recentCorrection = nil
        expectedCaretLocation = nil
        needsContextSync = true
    }
}

enum NativeSpellingCandidates {
    private static let cache = NSCache<NSString, NSArray>()

    static func prepare() {
        _ = NSSpellChecker.shared.checkSpelling(
            of: "cappy",
            startingAt: 0,
            language: "en_GB",
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
    }

    static func suggestions(for word: String) -> [String] {
        if let cached = cache.object(forKey: word as NSString) as? [String] {
            return cached
        }
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (word as NSString).length)
        let misspelling = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: "en_GB",
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        guard misspelling == range else {
            cache.setObject([] as NSArray, forKey: word as NSString)
            return []
        }
        let suggestions = checker.guesses(
            forWordRange: range,
            in: word,
            language: "en_GB",
            inSpellDocumentWithTag: 0
        ) ?? []
        cache.setObject(suggestions as NSArray, forKey: word as NSString)
        return suggestions
    }
}
