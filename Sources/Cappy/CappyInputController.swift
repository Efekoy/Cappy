import AppKit
import InputMethodKit

private struct CorrectionLedger {
    let generation: UInt64
    let range: NSRange
    let original: String
    let correctedText: String
    let replacement: String
    let suffix: String
    let expectedCaretLocation: Int
}

@objc(CappyInputController)
final class CappyInputController: IMKInputController {
    private let session = CorrectionSession()

    override func activateServer(_ sender: Any!) {
        ProtectedWords.shared.reload()
        session.invalidateSession()
        session.correctionsSuppressedForApp = SafetyPolicy.suppressesCorrections(
            bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
        super.activateServer(sender)
    }

    override func deactivateServer(_ sender: Any!) {
        session.finishSession()
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        session.invalidateSession()
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "Cappy")
        let item = NSMenuItem(title: "Edit words Cappy should keep…", action: #selector(editProtectedWords(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func editProtectedWords(_ sender: Any?) {
        _ = ProtectedWords.shared
        NSWorkspace.shared.open(ProtectedWords.userFileURL)
    }

    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        guard let string, !string.isEmpty, let client = sender as? any IMKTextInput else { return false }
        return session.processInput(string, client: IMKCorrectionClient(client: client))
    }

    override func didCommand(by aSelector: Selector!, client sender: Any!) -> Bool {
        guard let aSelector, let client = sender as? any IMKTextInput else {
            session.invalidateSession()
            return false
        }
        return session.didCommand(NSStringFromSelector(aSelector), client: IMKCorrectionClient(client: client))
    }
}

/// The small document interface used by both IMK and the integration tests.
protocol CorrectionClient {
    func selectedRange() -> NSRange
    func attributedSubstring(from range: NSRange) -> NSAttributedString?
    func insertText(_ string: String, replacementRange: NSRange)
}

private struct IMKCorrectionClient: CorrectionClient {
    let client: any IMKTextInput
    func selectedRange() -> NSRange { client.selectedRange() }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? { client.attributedSubstring(from: range) }
    func insertText(_ string: String, replacementRange: NSRange) { client.insertText(string, replacementRange: replacementRange) }
}

final class CorrectionSession {
    private var engine: FastCorrectionEngine
    private let personalization: PersonalizationStore

    init(personalization: PersonalizationStore = .shared, frequencyModel: WordFrequencyModel = .shared, protectedWords: ProtectedWords = .shared) {
        self.personalization = personalization
        engine = FastCorrectionEngine(
            candidateProvider: NativeSpellingCandidates.suggestions,
            suppressionProvider: { original, replacement in
                protectedWords.suppresses(original: original, replacement: replacement)
                    || personalization.shouldSuppress(original: original, replacement: replacement)
            },
            rerankProvider: ContextReranker.shared.decision,
            contextualSpellingProvider: frequencyModel.replacement
        )
    }
    private var recentCorrection: CorrectionLedger?
    private var expectedCaretLocation: Int?
    private var needsContextSync = true
    var correctionsSuppressedForApp = false

    func finishSession() {
        acceptRecentCorrection()
        invalidateSession()
    }

    func processInput(_ string: String, client: any CorrectionClient, commitsInput: Bool = true) -> Bool {
        let inputReceived = ContinuousClock.now

        // Enter can arrive as text instead of a command. Never change the
        // message at a line break, since the app may submit it immediately.
        if string.rangeOfCharacter(from: .newlines) != nil {
            acceptRecentCorrection()
            invalidateSession()
            if commitsInput { client.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            return commitsInput
        }

        if correctionsSuppressedForApp {
            if commitsInput { client.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            return commitsInput
        }

        reconcileCaret(with: client)
        synchronizeContextIfNeeded(from: client)
        acceptRecentCorrection()

        // Read the document before writing. IMK clients may report a stale caret
        // immediately after insertText, and replacing only the word after inserting
        // its space would put the caret before that space in native text views.
        let selection = client.selectedRange()
        let correction = engine.consume(string)
        PerformanceRecorder.shared.recordFastDecision(startedAt: inputReceived)

        if let correction,
           selection.location != NSNotFound,
           selection.length == 0 {
            let projectedCaret = NSRange(location: selection.location + (string as NSString).length, length: 0)
            if let sourceRange = CorrectionRangePlanner.sourceRange(for: correction, selection: projectedCaret),
               correction.suffix.hasSuffix(string),
               NSMaxRange(sourceRange) <= selection.location {
                let existingSuffix = String(correction.suffix.dropLast(string.count))
                let replacementRange = NSRange(location: sourceRange.location, length: sourceRange.length + (existingSuffix as NSString).length)
                guard NSMaxRange(replacementRange) == selection.location,
                      text(in: replacementRange, from: client) == correction.original + existingSuffix else {
                    invalidateSession()
                    if commitsInput { client.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0)) }
                    return commitsInput
                }
                // Replace the word and commit its separator in one transaction.
                client.insertText(correction.replacement + (commitsInput ? correction.suffix : existingSuffix), replacementRange: replacementRange)
                if !commitsInput {
                    invalidateSession()
                    return false
                }
                PerformanceRecorder.shared.recordReplacement(startedAt: inputReceived)
                let expectedCaret = sourceRange.location + correction.replacementUTF16Length + correction.suffixUTF16Length
                recentCorrection = CorrectionLedger(
                    generation: engine.generation,
                    range: CorrectionRangePlanner.undoRange(for: correction, sourceRange: sourceRange),
                    original: correction.original,
                    correctedText: correction.replacement + correction.suffix,
                    replacement: correction.replacement,
                    suffix: correction.suffix,
                    expectedCaretLocation: expectedCaret
                )
                expectedCaretLocation = expectedCaret
                return true
            }
            invalidateSession()
        }

        guard commitsInput else { return false }
        client.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
        expectedCaretLocation = selection.location == NSNotFound ? nil : selection.location + (string as NSString).length
        return true
    }

    func didCommand(_ command: String, client: any CorrectionClient) -> Bool {
        if command == "insertSpace:" {
            return processInput(" ", client: client)
        }
        if ["insertNewline:", "insertNewlineIgnoringFieldEditor:", "insertLineBreak:", "insertParagraphSeparator:"].contains(command) {
            // Let the app handle Enter without applying an unchecked correction.
            acceptRecentCorrection()
            invalidateSession()
            return false
        }
        if ["insertTab:", "insertBacktab:"].contains(command) {
            // Tab may move focus. Correct the completed word, then pass it on.
            _ = processInput("\t", client: client, commitsInput: false)
            acceptRecentCorrection()
            invalidateSession()
            return false
        }
        if command == "deleteBackward:", restoreRecentCorrection(in: client, removingSuffix: true) {
            return true
        }
        if command == "undo:", restoreRecentCorrection(in: client, removingSuffix: false) {
            return true
        }
        acceptRecentCorrection()
        invalidateSession()
        return false
    }

    private func restoreRecentCorrection(in client: any CorrectionClient, removingSuffix: Bool) -> Bool {
        guard let correction = recentCorrection,
              correction.generation == engine.generation else { return false }
        let selection = client.selectedRange()
        guard selection.location == correction.expectedCaretLocation,
              selection.length == 0,
              text(in: correction.range, from: client) == correction.correctedText else {
            invalidateSession()
            return false
        }

        let restored = correction.original + (removingSuffix ? String(correction.suffix.dropLast()) : correction.suffix)
        client.insertText(restored, replacementRange: correction.range)
        personalization.recordRejected(
            original: correction.original,
            replacement: correction.replacement
        )
        recentCorrection = nil
        invalidateSession()
        expectedCaretLocation = correction.range.location + (restored as NSString).length
        return true
    }

    private func acceptRecentCorrection() {
        guard let correction = recentCorrection else { return }
        personalization.recordAccepted(
            original: correction.original,
            replacement: correction.replacement
        )
        recentCorrection = nil
    }

    private func reconcileCaret(with client: any CorrectionClient) {
        guard let expectedCaretLocation else { return }
        let current = client.selectedRange()
        if current.location != NSNotFound,
           (current.location != expectedCaretLocation || current.length != 0) {
            invalidateSession()
        }
    }

    private func synchronizeContextIfNeeded(from client: any CorrectionClient) {
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

    private func text(in range: NSRange, from client: any CorrectionClient) -> String? {
        guard range.location != NSNotFound,
              let attributed = client.attributedSubstring(from: range),
              attributed.length == range.length else { return nil }
        return attributed.string
    }

    func invalidateSession() {
        engine.invalidate()
        recentCorrection = nil
        expectedCaretLocation = nil
        needsContextSync = true
    }
}

private enum SafetyPolicy {
    private static let suppressedBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.apple.dt.Xcode",
        "com.googlecode.iterm2",
        "com.microsoft.VSCode"
    ]

    static func suppressesCorrections(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return suppressedBundleIdentifiers.contains(bundleIdentifier)
    }
}

enum NativeSpellingCandidates {
    private static let cache: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.countLimit = 512
        return cache
    }()

    private static let alternativesCache: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.countLimit = 512
        return cache
    }()

    static func alternatives(for word: String) -> [String] {
        if let cached = alternativesCache.object(forKey: word as NSString) as? [String] { return cached }
        let result = NSSpellChecker.shared.guesses(
            forWordRange: NSRange(location: 0, length: (word as NSString).length),
            in: word, language: "en_GB", inSpellDocumentWithTag: 0
        ) ?? []
        alternativesCache.setObject(result as NSArray, forKey: word as NSString)
        return result
    }

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
        let preferred = checker.correction(
            forWordRange: range, in: word, language: "en_GB", inSpellDocumentWithTag: 0
        )
        let misspelling = checker.checkSpelling(
            of: word, startingAt: 0, language: "en_GB", wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil
        )
        guard preferred != nil || misspelling == range else {
            cache.setObject([] as NSArray, forKey: word as NSString)
            return []
        }
        var suggestions = checker.guesses(
            forWordRange: range, in: word, language: "en_GB", inSpellDocumentWithTag: 0
        ) ?? []
        if let preferred {
            suggestions.removeAll { $0 == preferred }
            suggestions.insert(preferred, at: 0)
        }
        // Preserve all letters when the dictionary offers an apostrophe-only
        // repair. This does not require a manually maintained contraction table.
        if let contraction = suggestions.first(where: {
            $0.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "").lowercased() == word.lowercased()
                && $0.contains(where: { $0 == "'" || $0 == "’" })
        }) {
            suggestions.removeAll { $0 == contraction }
            suggestions.insert(contraction, at: 0)
        }
        cache.setObject(suggestions as NSArray, forKey: word as NSString)
        return suggestions
    }
}
