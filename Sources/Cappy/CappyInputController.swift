import AppKit
import InputMethodKit
import Carbon
import os

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
    private var eventRouter = CorrectionEventRouter()
    private var reportedInputPath = false

    private func connectOverlay() {
        session.onHide = { [weak self] in self?.overlay.hide() }
        session.onPresentation = { [weak self] presentation, client in
            guard let self else { return false }
            return self.overlay.show(presentation, client: client,
                primary: { [weak self] in
                    guard let self else { return }
                    switch presentation {
                    case .corrected, .manualCorrected: _ = self.session.didCommand("undo:", client: client)
                    case .suggestion: _ = self.session.acceptSuggestion(in: client)
                    case .keep: _ = self.session.alwaysKeep()
                    case .status: break
                    }
                }, secondary: { [weak self] in self?.session.dismissPresentation() },
                expired: { [weak self] in self?.session.expirePresentation() })
        }
    }

    override func activateServer(_ sender: Any!) {
        reportedInputPath = false
        eventRouter.reset()
        connectOverlay()
        ProtectedWords.shared.reload()
        session.invalidateSession()
        // Activation may occur while the input-source menu is frontmost. The
        // IMK client identifies the actual app receiving the keyboard event.
        let bundleIdentifier = (sender as? any IMKTextInput)?.bundleIdentifier()
            ?? client()?.bundleIdentifier()
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        session.correctionsSuppressedForApp = SafetyPolicy.suppressesCorrections(bundleIdentifier: bundleIdentifier)
        session.usesNativeTyping = InputClientPolicy.usesNativeTyping(bundleIdentifier: bundleIdentifier)
        Logger(subsystem: "com.efekoy.inputmethod.Cappy", category: "client").debug("Client \(bundleIdentifier ?? "unknown", privacy: .public), native typing \(self.session.usesNativeTyping, privacy: .public)")
        ManualCorrectionShortcut.shared.activate(self)
        super.activateServer(sender)
    }

    override func deactivateServer(_ sender: Any!) {
        eventRouter.reset()
        ManualCorrectionShortcut.shared.deactivate(self)
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
        let correct = NSMenuItem(title: "Correct Written Text (⌘⌥⇧C)", action: #selector(correctWrittenText(_:)), keyEquivalent: "")
        correct.target = self
        menu.addItem(correct)
        menu.addItem(item)
        return menu
    }

    @objc func correctWrittenText(_ sender: Any?) {
        Logger(subsystem: "com.efekoy.inputmethod.Cappy", category: "manual").debug("Manual correction invoked")
        guard let client = client() else { return }
        _ = session.correctWrittenText(in: IMKCorrectionClient(client: client))
    }

    @objc private func editProtectedWords(_ sender: Any?) {
        PersonalisationSettingsController.shared.show()
    }

    // Receive the original event before IMK's decoded keybinding layer. Returning
    // false here forwards that event, including Chromium's native omnibox keys.
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        if !reportedInputPath {
            reportedInputPath = true
            let identifier = (sender as? any IMKTextInput)?.bundleIdentifier() ?? "unknown"
            Logger(subsystem: "com.efekoy.inputmethod.Cappy", category: "client").notice("Raw input callback: client \(identifier, privacy: .public), text present \(!(event?.characters?.isEmpty ?? true)), native typing \(self.session.usesNativeTyping)")
        }
        guard let event, let client = sender as? any IMKTextInput else { return false }
        return eventRouter.handle(event, session: session, client: IMKCorrectionClient(client: client))
    }

    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        if !reportedInputPath {
            reportedInputPath = true
            let identifier = (sender as? any IMKTextInput)?.bundleIdentifier() ?? "unknown"
            Logger(subsystem: "com.efekoy.inputmethod.Cappy", category: "client").notice("Decoded input callback: client \(identifier, privacy: .public), text present \(!(string?.isEmpty ?? true)), native typing \(self.session.usesNativeTyping)")
        }
        guard let string, !string.isEmpty, let client = sender as? any IMKTextInput else { return false }
        let adapter = IMKCorrectionClient(client: client)
        if string == "\t", session.hasSuggestion { return session.didCommand("insertTab:", client: adapter) }
        if session.usesNativeTyping { return session.processNativeInput(string, client: adapter) }
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
    func insertAttributedText(_ text: NSAttributedString, replacementRange: NSRange)
}
extension CorrectionClient {
    func caretRect() -> NSRect? { nil }
    func insertAttributedText(_ text: NSAttributedString, replacementRange: NSRange) {
        insertText(text.string, replacementRange: replacementRange)
    }
}

enum SessionPresentation {
    case corrected(FastCorrection)
    case suggestion(FastCorrection)
    case keep(String)
    case manualCorrected(Int)
    case status(String)
}


private struct IMKCorrectionClient: CorrectionClient {
    let client: any IMKTextInput
    func selectedRange() -> NSRange { client.selectedRange() }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? { client.attributedSubstring(from: range) }
    func insertText(_ string: String, replacementRange: NSRange) { client.insertText(string, replacementRange: replacementRange) }
    func insertAttributedText(_ text: NSAttributedString, replacementRange: NSRange) { client.insertText(text, replacementRange: replacementRange) }
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
                // Ignoring a popup is not a request to stop capitalising the English pronoun.
                // Explicit undo/rejection and protected words still override this rule.
                return personalization.adjustment(original: candidate.source, replacement: candidate.replacement, context: candidate.contextSignature,
                    includeIgnoredSuggestions: !(candidate.type == "case" && candidate.source == "i" && candidate.replacement == "I"))
            },
            observationProvider: { token in
                let technical = token == token.uppercased() || !ContextualPhraseRanker.simple(token)
                personalization.observeIntentional(token, unfamiliar: !technical && frequencyModel.count(token) == nil
                    && !NativeSpellingCandidates.cachedSuggestions(for: token.lowercased()).isEmpty)
            }
        )
    }
    private var manualCorrection: (range: NSRange, original: NSAttributedString, replacement: NSAttributedString, caret: Int)?
    private var recentCorrection: CorrectionLedger?
    private var expectedCaretLocation: Int?
    private var needsContextSync = true
    var correctionsSuppressedForApp = false
    var usesNativeTyping = false

    /// Explicit, bounded review of selected text or the paragraph before the caret.
    /// No clipboard, Accessibility access, or continuous document history.
    @discardableResult func correctWrittenText(in client: any CorrectionClient) -> Bool {
        acceptRecentCorrection()
        invalidateSession()
        func status(_ message: String) -> Bool {
            _ = onPresentation?(.status(message), client)
            return false
        }
        guard !correctionsSuppressedForApp else { return status("Cappy is disabled in this app") }
        let selection = client.selectedRange()
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= Int.max - selection.length,
              selection.length <= ManualTextCorrection.maximumUTF16Length else {
            return status("Select up to 4,096 characters to correct")
        }
        var range = selection
        if selection.length == 0 {
            let length = min(selection.location, ManualTextCorrection.maximumUTF16Length)
            range = NSRange(location: selection.location - length, length: length)
        }
        guard let captured = client.attributedSubstring(from: range), captured.length == range.length else {
            return status("This field does not expose text to Cappy")
        }
        let snapshot = captured.string
        var attributedSource = NSAttributedString(attributedString: captured)
        var source = snapshot
        if selection.length == 0 {
            let string = snapshot as NSString
            let newline = string.rangeOfCharacter(from: .newlines, options: .backwards)
            if newline.location != NSNotFound {
                let offset = NSMaxRange(newline)
                source = string.substring(from: offset)
                attributedSource = attributedSource.attributedSubstring(from: NSRange(location: offset, length: string.length - offset))
                range = NSRange(location: range.location + offset, length: string.length - offset)
            } else if range.location > 0 {
                return status("Select a shorter passage to correct")
            }
        }
        guard !source.isEmpty else { return status("No text to correct") }
        guard let result = ManualTextCorrection.correct(source, using: engine) else {
            return status("Review timed out; select a shorter passage")
        }
        guard result.text != source else { return status("No confident corrections found") }
        // Re-read after all dictionary/model work, including a final selection check.
        guard client.selectedRange() == selection,
              client.attributedSubstring(from: range)?.isEqual(to: attributedSource) == true,
              client.selectedRange() == selection else { return status("Text changed; correction cancelled") }
        let corrected = NSMutableAttributedString(attributedString: attributedSource)
        for edit in result.edits {
            // NSString replacement inherits the original span’s attributes.
            corrected.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        guard corrected.string == result.text else { return status("Correction cancelled") }
        client.insertAttributedText(corrected, replacementRange: range)
        let caret = range.location + (result.text as NSString).length
        manualCorrection = (NSRange(location: range.location, length: (result.text as NSString).length), attributedSource, NSAttributedString(attributedString: corrected), caret)
        expectedCaretLocation = caret
        _ = onPresentation?(.manualCorrected(result.count), client)
        return true
    }

    private func restoreManualCorrection(in client: any CorrectionClient) -> Bool {
        guard let correction = manualCorrection else { return false }
        let selection = client.selectedRange()
        guard selection == NSRange(location: correction.caret, length: 0),
              client.attributedSubstring(from: correction.range)?.isEqual(to: correction.replacement) == true,
              client.selectedRange() == selection else { invalidateSession(); return false }
        client.insertAttributedText(correction.original, replacementRange: correction.range)
        invalidateSession()
        return true
    }

    func finishSession() {
        acceptRecentCorrection()
        invalidateSession()
        personalization.flush()
    }

    /// Chrome must insert its own ordinary key events. Query/replace only at
    /// spaces, and always forward that original separator to the host afterwards.
    /// An unsupported client therefore still receives every typed character.
    func processNativeInput(_ string: String, client: any CorrectionClient) -> Bool {
        acceptRecentCorrection()
        invalidateSession()
        guard string == " ", !correctionsSuppressedForApp else { return false }
        return processInput(string, client: client, commitsInput: false, tracksForwardedBoundary: true)
    }

    func processInput(_ string: String, client: any CorrectionClient, commitsInput: Bool = true,
                      tracksForwardedBoundary: Bool = false) -> Bool {
        manualCorrection = nil
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
                if !commitsInput && !tracksForwardedBoundary {
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
                return commitsInput
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
        if command == "undo:", restoreManualCorrection(in: client) { return true }
        manualCorrection = nil
        if command == "insertTab:", hasSuggestion { return acceptSuggestion(in: client) }
        if command == "cancelOperation:", hasSuggestion {
            discardSuggestion(.suggestionRejected); onHide?(); return true
        }
        if command != "insertSpace:" { discardSuggestion(.suggestionIgnored) }
        if command == "insertSpace:", usesNativeTyping { return processNativeInput(" ", client: client) }
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
        manualCorrection = nil
        discardSuggestion(.suggestionIgnored)
        undoneSource = nil
        onHide?()
        engine.invalidate()
        recentCorrection = nil
        expectedCaretLocation = nil
        needsContextSync = true
    }
}

enum InputClientPolicy {
    static func usesNativeTyping(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.google.Chrome" || bundleIdentifier.hasPrefix("com.google.Chrome.")
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

/// Register only while a Cappy client is active. Carbon hotkeys do not require
/// Accessibility permission and leave the existing IMK input routing untouched.
private final class ManualCorrectionShortcut {
    static let shared = ManualCorrectionShortcut()
    private weak var activeController: CappyInputController?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x43617079 // Capy

    private init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == ManualCorrectionShortcut.shared.signature, identifier.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            ManualCorrectionShortcut.shared.activeController?.correctWrittenText(nil)
            return noErr
        }, 1, &event, nil, &handler)
    }
    func activate(_ controller: CappyInputController) {
        activeController = controller
        guard handler != nil, hotKey == nil else { return }
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(cmdKey | optionKey | shiftKey),
            EventHotKeyID(signature: signature, id: 1), GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        Logger(subsystem: "com.efekoy.inputmethod.Cappy", category: "manual").debug("Shortcut registration status \(result, privacy: .public)")
        if result != noErr { NSLog("Cappy: manual correction shortcut unavailable (%d); use the input menu", result) }
    }
    func deactivate(_ controller: CappyInputController) {
        guard activeController === controller else { return }
        activeController = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}

/// Runs the existing high-confidence pipeline against an in-memory snapshot.
/// Each phrase replacement is verified against the snapshot, preserving every
/// separator. An artificial final boundary is removed before returning.
enum ManualTextCorrection {
    static let maximumUTF16Length = 4096
    struct Edit { let range: NSRange; let replacement: String }
    struct Result { let text: String; let edits: [Edit]; var count: Int { edits.count } }
    static func correct(_ source: String, using originalEngine: FastCorrectionEngine,
                        timeLimit: Duration = .seconds(1)) -> Result? {
        guard (source as NSString).length <= maximumUTF16Length else { return nil }
        var engine = originalEngine
        engine.invalidate()
        engine.disableObservations()
        var output = ""
        var edits: [Edit] = []
        let start = ContinuousClock.now
        for character in source + " " {
            if ContinuousClock.now - start > timeLimit { return nil }
            output.append(character)
            guard let correction = engine.consume(String(character)) else { continue }
            let expected = correction.original + correction.suffix
            guard output.hasSuffix(expected) else { engine.invalidate(); continue }
            edits.append(Edit(range: NSRange(location: (output as NSString).length - (expected as NSString).length, length: correction.originalUTF16Length), replacement: correction.replacement))
            output.removeLast(expected.count)
            output += correction.replacement + correction.suffix
        }
        guard ContinuousClock.now - start <= timeLimit else { return nil }
        output.removeLast() // synthetic boundary, never inserted into the document
        return Result(text: output, edits: edits)
    }
}

/// Direct IMK event routing. Command shortcuts and native composition keep their
/// original events; editing commands retain the existing session validation/undo.
struct CorrectionEventRouter {
    private var forwardsCompositionContinuation = false
    mutating func reset() { forwardsCompositionContinuation = false }
    mutating func handle(_ event: NSEvent, session: CorrectionSession, client: any CorrectionClient) -> Bool {
        guard event.type == .keyDown else { return false }
        guard !session.correctionsSuppressedForApp else {
            reset(); session.invalidateSession(); return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            reset()
            if !modifiers.contains(.shift), !modifiers.contains(.option),
               event.charactersIgnoringModifiers?.lowercased() == "z" {
                return session.didCommand("undo:", client: client)
            }
            session.invalidateSession()
            return false
        }
        if modifiers.contains(.control) {
            reset(); session.invalidateSession(); return false
        }
        // Let AppKit interpret Option characters/dead keys, and their following
        // text event, rather than inserting an uncomposed accent ourselves.
        if modifiers.contains(.option) {
            forwardsCompositionContinuation = true
            session.invalidateSession()
            return false
        }
        if forwardsCompositionContinuation {
            reset(); session.invalidateSession(); return false
        }
        let command: String?
        switch event.keyCode {
        case 36, 76: command = "insertNewline:"
        case 48: command = modifiers.contains(.shift) ? "insertBacktab:" : "insertTab:"
        case 51: command = "deleteBackward:"
        case 53: command = "cancelOperation:"
        case 117: command = "deleteForward:"
        case 123: command = "moveLeft:"
        case 124: command = "moveRight:"
        case 125: command = "moveDown:"
        case 126: command = "moveUp:"
        case 115: command = "moveToBeginningOfDocument:"
        case 119: command = "moveToEndOfDocument:"
        case 116: command = "pageUp:"
        case 121: command = "pageDown:"
        default: command = nil
        }
        if let command { return session.didCommand(command, client: client) }
        guard let text = event.characters, !text.isEmpty,
              !text.unicodeScalars.contains(where: { $0.value < 0x20 || (0xF700...0xF8FF).contains($0.value) }) else {
            session.invalidateSession(); return false
        }
        if session.usesNativeTyping { return session.processNativeInput(text, client: client) }
        return session.processInput(text, client: client)
    }
}
