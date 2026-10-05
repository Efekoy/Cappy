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
    let candidate: CorrectionCandidate?
    var wasSuggestion = false
}

@objc(CappyInputController)
final class CappyInputController: IMKInputController {
    private let session = CorrectionSession()
    private let overlay = CorrectionOverlayController()

    private func connectOverlay() {
        session.onHide = { [weak self] in self?.overlay.hide() }
        session.onPresentation = { [weak self] presentation, client in
            guard let self else { return false }
            return self.overlay.show(presentation, client: client,
                primary: { [weak self] in
                    guard let self else { return }
                    switch presentation {
                    case .corrected: _ = self.session.didCommand("undo:", client: client)
                    case .suggestion: _ = self.session.acceptSuggestion(in: client)
                    case .keep: _ = self.session.alwaysKeep()
                    }
                }, secondary: { [weak self] in self?.session.dismissPresentation() },
                expired: { [weak self] in self?.session.expirePresentation() })
        }
    }

    override func activateServer(_ sender: Any!) {
        connectOverlay()
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
        let item = NSMenuItem(title: "Cappy Settings…", action: #selector(editProtectedWords(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func editProtectedWords(_ sender: Any?) {
        PersonalisationSettingsController.shared.show()
    }

    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        guard let string, !string.isEmpty, let client = sender as? any IMKTextInput else { return false }
        let adapter = IMKCorrectionClient(client: client)
        if string == "\t", session.hasSuggestion { return session.didCommand("insertTab:", client: adapter) }
        return session.processInput(string, client: adapter)
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
    func caretRect() -> NSRect?
}
extension CorrectionClient { func caretRect() -> NSRect? { nil } }

enum SessionPresentation {
    case corrected(FastCorrection)
    case suggestion(FastCorrection)
    case keep(String)
}


private struct IMKCorrectionClient: CorrectionClient {
    let client: any IMKTextInput
    func selectedRange() -> NSRange { client.selectedRange() }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? { client.attributedSubstring(from: range) }
    func insertText(_ string: String, replacementRange: NSRange) { client.insertText(string, replacementRange: replacementRange) }
    func caretRect() -> NSRect? {
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.height > 0, rect.height < 200,
              NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else { return nil }
        return rect
    }
}

final class CorrectionSession {
    private var engine: FastCorrectionEngine
    private let personalization: PersonalizationStore
    private let protectedWords: ProtectedWords
    private var pendingSuggestion: (correction: FastCorrection, candidate: CorrectionCandidate, range: NSRange, caret: Int, generation: UInt64)?
    private var undoneSource: (source: String, replacement: String, context: String)?
    var hasSuggestion: Bool { pendingSuggestion != nil }
    var onPresentation: ((SessionPresentation, any CorrectionClient) -> Bool)?
    var onHide: (() -> Void)?

    init(personalization: PersonalizationStore = .shared, frequencyModel: WordFrequencyModel = .shared, protectedWords: ProtectedWords = .shared, phraseCandidateProvider: (([String]) -> [CorrectionCandidate])? = nil) {
        self.personalization = personalization
        self.protectedWords = protectedWords
        engine = FastCorrectionEngine(
            candidateProvider: NativeSpellingCandidates.suggestions,
            suppressionProvider: { original, replacement in
                protectedWords.suppresses(original: original, replacement: replacement)
                    || personalization.shouldSuppress(original: original, replacement: replacement)
                    || original.split(separator: " ").contains { personalization.vocabularyState(String($0), protectedWords: protectedWords) == .likelyIntentional }
            },
            rerankProvider: ContextReranker.shared.decision,
            contextualSpellingProvider: frequencyModel.replacement,
            phraseProvider: phraseCandidateProvider ?? ContextualPhraseRanker(frequencies: frequencyModel, provider: NativeSpellingCandidates.cachedSuggestions).candidates,
            personalScore: { candidate in
                if personalization.shouldSuppress(original: candidate.source, replacement: candidate.replacement, context: candidate.contextSignature) { return -1 }
                return personalization.adjustment(original: candidate.source, replacement: candidate.replacement, context: candidate.contextSignature)
            },
            observationProvider: { token in
                let technical = token == token.uppercased() || !ContextualPhraseRanker.simple(token)
                personalization.observeIntentional(token, unfamiliar: !technical && frequencyModel.count(token) == nil
                    && !NativeSpellingCandidates.cachedSuggestions(for: token.lowercased()).isEmpty)
            }
        )
    }
    private var recentCorrection: CorrectionLedger?
    private var expectedCaretLocation: Int?
    private var needsContextSync = true
    var correctionsSuppressedForApp = false

    func finishSession() {
        acceptRecentCorrection()
        invalidateSession()
        personalization.flush()
    }

    func processInput(_ string: String, client: any CorrectionClient, commitsInput: Bool = true) -> Bool {
        let inputReceived = ContinuousClock.now
        discardSuggestion(.suggestionIgnored)
        undoneSource = nil
        onHide?()

        // Enter can arrive as text instead of a command. Never change the
        // message at a line break, since the app may submit it immediately.
        if string.rangeOfCharacter(from: .newlines) != nil {
            acceptRecentCorrection()
            invalidateSession()
            if commitsInput { client.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            return commitsInput
        }

        // Bulk insertion/paste has no already-committed source span to validate.
        // Pass it through without doing dictionary/model work for every word.
        if string.count > 1 && string.contains(where: \.isWhitespace) {
            acceptRecentCorrection(); invalidateSession()
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
                      text(in: replacementRange, from: client) == correction.original + existingSuffix,
                      client.selectedRange() == selection else {
                    invalidateSession()
                    if commitsInput { client.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0)) }
                    return commitsInput
                }
                engine.locateCandidate(in: sourceRange)
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
                    expectedCaretLocation: expectedCaret,
                    candidate: engine.lastCandidate
                )
                expectedCaretLocation = expectedCaret
                _ = onPresentation?(.corrected(correction), client)
                return true
            }
            invalidateSession()
        }

        guard commitsInput else { return false }
        client.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
        expectedCaretLocation = selection.location == NSNotFound ? nil : selection.location + (string as NSString).length
        if let suggestion = engine.suggestion, var candidate = engine.lastCandidate,
           let caret = expectedCaretLocation,
           let range = CorrectionRangePlanner.sourceRange(for: suggestion, selection: NSRange(location: caret, length: 0)),
           selection.length == 0,
           text(in: NSRange(location: range.location, length: range.length + suggestion.suffixUTF16Length), from: client) == suggestion.original + suggestion.suffix {
            candidate.sourceRange = range
            pendingSuggestion = (suggestion, candidate, range, caret, engine.generation)
            if onPresentation?(.suggestion(suggestion), client) == false { pendingSuggestion = nil }
        }
        return true
    }

    func didCommand(_ command: String, client: any CorrectionClient) -> Bool {
        if command == "insertTab:", hasSuggestion { return acceptSuggestion(in: client) }
        if command == "cancelOperation:", hasSuggestion {
            discardSuggestion(.suggestionRejected); onHide?(); return true
        }
        if command != "insertSpace:" { discardSuggestion(.suggestionIgnored) }
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
              text(in: correction.range, from: client) == correction.correctedText,
              client.selectedRange() == selection else {
            invalidateSession()
            return false
        }

        let restored = correction.original + (removingSuffix ? String(correction.suffix.dropLast()) : correction.suffix)
        client.insertText(restored, replacementRange: correction.range)
        personalization.record(correction.wasSuggestion ? .suggestionRejected : .automaticUndone,
            original: correction.original, replacement: correction.replacement,
            context: correction.candidate?.contextSignature ?? "")
        recentCorrection = nil
        invalidateSession()
        expectedCaretLocation = correction.range.location + (restored as NSString).length
        undoneSource = (correction.original, correction.replacement, correction.candidate?.contextSignature ?? "")
        _ = onPresentation?(.keep(correction.original), client)
        return true
    }

    private func acceptRecentCorrection() {
        guard let correction = recentCorrection else { return }
        if !correction.wasSuggestion {
            personalization.record(.automaticAccepted, original: correction.original,
                replacement: correction.replacement, context: correction.candidate?.contextSignature ?? "")
        }
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

    @discardableResult func acceptSuggestion(in client: any CorrectionClient) -> Bool {
        guard let pending = pendingSuggestion else { return false }
        let selection = client.selectedRange()
        let fullRange = NSRange(location: pending.range.location,
            length: pending.range.length + pending.correction.suffixUTF16Length)
        guard pending.generation == engine.generation,
              selection == NSRange(location: pending.caret, length: 0),
              text(in: fullRange, from: client) == pending.correction.original + pending.correction.suffix,
              client.selectedRange() == selection else {
            invalidateSession(); return false
        }
        let correction = pending.correction
        client.insertText(correction.replacement + correction.suffix, replacementRange: fullRange)
        pendingSuggestion = nil
        personalization.record(.suggestionAccepted, original: correction.original,
            replacement: correction.replacement, context: pending.candidate.contextSignature)
        engine.invalidate(); needsContextSync = true
        let caret = fullRange.location + correction.replacementUTF16Length + correction.suffixUTF16Length
        recentCorrection = CorrectionLedger(generation: engine.generation,
            range: NSRange(location: fullRange.location, length: correction.replacementUTF16Length + correction.suffixUTF16Length),
            original: correction.original, correctedText: correction.replacement + correction.suffix,
            replacement: correction.replacement, suffix: correction.suffix, expectedCaretLocation: caret,
            candidate: pending.candidate, wasSuggestion: true)
        expectedCaretLocation = caret
        _ = onPresentation?(.corrected(correction), client)
        return true
    }

    @discardableResult func alwaysKeep() -> Bool {
        guard let source = undoneSource else { return false }
        let tokens = source.source.split(separator: " ").map(String.init)
        if tokens.count == 1 {
            guard protectedWords.protect(source.source) else { return false }
            personalization.observeIntentional(source.source)
        } else {
            // Explicit phrase suppression never whitelists incidental neighbours.
            personalization.suppressPair(original: source.source, replacement: source.replacement, context: source.context)
        }
        personalization.flush()
        undoneSource = nil; onHide?(); return true
    }

    func expirePresentation() {
        discardSuggestion(.suggestionIgnored); undoneSource = nil; onHide?()
    }

    func dismissPresentation() {
        discardSuggestion(.suggestionRejected); undoneSource = nil; onHide?()
    }

    private func discardSuggestion(_ interaction: PersonalInteraction) {
        guard let pending = pendingSuggestion else { return }
        personalization.record(interaction, original: pending.correction.original,
            replacement: pending.correction.replacement, context: pending.candidate.contextSignature)
        pendingSuggestion = nil
    }

    func invalidateSession() {
        discardSuggestion(.suggestionIgnored)
        undoneSource = nil
        onHide?()
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

    static func cachedSuggestions(for word: String) -> [String] {
        cache.object(forKey: word as NSString) as? [String] ?? []
    }

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
