import AppKit
import InputMethodKit
import Carbon
import os
import ApplicationServices

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
        if session.scheduler == nil { session.scheduler = BackgroundCorrectionScheduler() }
        session.onHide = { [weak self] in self?.overlay.hide() }
        session.onContinueTyping = { [weak self] anchor in self?.overlay.updateAnchor(anchor) }
        session.onUndo = { [weak self] in self?.overlay.clearHighlights() }
        session.onPresentation = { [weak self] presentation, client in
            guard let self else { return false }
            return self.overlay.show(presentation, client: client, anchor: self.session.presentationAnchor,
                primary: { [weak self] in
                    guard let self else { return }
                    switch presentation {
                    case .corrected: _ = self.session.undoCorrection(in: client)
                    case .suggestion: _ = self.session.acceptSuggestion(in: client)
                    case .keep: _ = self.session.alwaysKeep(client: client)
                    case .learned: break
                    }
                }, secondary: { [weak self] in self?.session.dismissPresentation(client: client) },
                expired: { [weak self] in self?.session.expirePresentation() })
        }
    }

    override func activateServer(_ sender: Any!) {
        overlay.clearHighlights()
        AccessibleWordBounds.resetCaches()
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
        super.activateServer(sender)
    }

    override func deactivateServer(_ sender: Any!) {
        overlay.clearHighlights()
        eventRouter.reset()
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
        let undo = NSMenuItem(title: "Undo Cappy Correction (⌃⌥Z)", action: #selector(undoLastCorrection(_:)), keyEquivalent: "")
        undo.target = self
        menu.addItem(undo)
        let highlights = NSMenuItem(title: "Enable Cross-App Highlights…", action: #selector(enableWordHighlights(_:)), keyEquivalent: "")
        highlights.target = self
        menu.addItem(highlights)
        menu.addItem(item)
        return menu
    }

    @objc func undoLastCorrection(_ sender: Any?) {
        guard let client = client() else { return }
        _ = session.undoCorrection(in: IMKCorrectionClient(client: client))
    }

    @objc private func enableWordHighlights(_ sender: Any?) {
        AccessibleWordBounds.requestAccess()
    }

    @objc private func editProtectedWords(_ sender: Any?) {
        PersonalisationSettingsController.shared.show()
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.leftMouseDown.rawValue)
    }

    // Receive the original event before IMK's decoded keybinding layer. Returning
    // false here forwards that event, including Chromium's native omnibox keys.
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? any IMKTextInput else { return false }
        if event.type == .leftMouseDown { session.invalidateSession(); return false }
        TypingActivity.noteKey()
        if !reportedInputPath {
            reportedInputPath = true
            let identifier = (sender as? any IMKTextInput)?.bundleIdentifier() ?? "unknown"
            Logger(subsystem: "com.efekoy.inputmethod.Cappy", category: "client").notice("Raw input callback: client \(identifier, privacy: .public), text present \(!(event.characters?.isEmpty ?? true)), native typing \(self.session.usesNativeTyping)")
        }
        return eventRouter.handle(event, session: session, client: IMKCorrectionClient(client: client))
    }

    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        TypingActivity.noteKey()
        if !reportedInputPath {
            reportedInputPath = true
            let identifier = (sender as? any IMKTextInput)?.bundleIdentifier() ?? "unknown"
            Logger(subsystem: "com.efekoy.inputmethod.Cappy", category: "client").notice("Decoded input callback: client \(identifier, privacy: .public), text present \(!(string?.isEmpty ?? true)), native typing \(self.session.usesNativeTyping)")
        }
        guard let string, !string.isEmpty, let client = sender as? any IMKTextInput else { return false }
        let adapter = IMKCorrectionClient(client: client)
        if string == "\t" { return session.didCommand("insertTab:", client: adapter) }
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
    func textRect(for range: NSRange) -> NSRect?
    /// Exact bounds of `text` at `range`, possibly delivered later on the main
    /// thread. Never estimated: hosts without exact geometry get no callback.
    func resolveTextRect(for range: NSRange, text: String, lookup: WordBoundsLookup,
                         completion: @escaping (NSRect) -> Void)
    /// A coarse area (editor or window) used only when neither the range nor
    /// the caret has geometry, so feedback still appears in every app.
    func approximateAnchorRect() -> NSRect?
    func insertAttributedText(_ text: NSAttributedString, replacementRange: NSRange)
}
extension CorrectionClient {
    func caretRect() -> NSRect? { nil }
    func textRect(for range: NSRange) -> NSRect? { nil }
    func resolveTextRect(for range: NSRange, text: String, lookup: WordBoundsLookup,
                         completion: @escaping (NSRect) -> Void) {
        if let rect = textRect(for: range) { completion(rect) }
    }
    func approximateAnchorRect() -> NSRect? { nil }
    func insertAttributedText(_ text: NSAttributedString, replacementRange: NSRange) {
        insertText(text.string, replacementRange: replacementRange)
    }
}

enum SessionPresentation {
    case corrected(FastCorrection)
    case suggestion(FastCorrection)
    case keep(String)
    case learned(String)
}


/// Read-only fallback for editors that expose text bounds through Accessibility
/// but not InputMethodKit. No automatic permission prompt or selection changes.
enum AccessibleWordBounds {
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func screenRect(_ bounds: CGRect, primaryScreenTop: CGFloat) -> NSRect? {
        let rect = NSRect(x: bounds.minX, y: primaryScreenTop - bounds.maxY,
            width: bounds.width, height: bounds.height)
        return CorrectionOverlayGeometry.isUsable(rect) && rect.width > 1 ? rect : nil
    }

    static let cacheLifetime: TimeInterval = 0.3

    /// The insertion point from Accessibility, for hosts whose IMK caret query
    /// is empty. Results, including failures, are reused briefly.
    private static var caretCache: (pid: pid_t, selection: NSRange, rect: NSRect?, expires: TimeInterval)?

    static func caretRect(client: any IMKTextInput) -> NSRect? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == client.bundleIdentifier() else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let selection = client.selectedRange()
        if let cached = caretCache, cached.pid == app.processIdentifier, cached.selection == selection, now < cached.expires {
            return cached.rect
        }
        CrossAppAccessibility.prepare(app)
        let rect = CrossAppAccessibility.focusedEditor(in: app).flatMap(CrossAppAccessibility.caretMarkerBounds)
        caretCache = (app.processIdentifier, selection, rect, now + cacheLifetime)
        return rect
    }

    /// Where to show feedback when neither the word nor the caret has
    /// geometry: the focused editor's frame, or else the app's window.
    private static var areaCache: (pid: pid_t, rect: NSRect?, expires: TimeInterval)?

    static func approximateArea(client: any IMKTextInput) -> NSRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == client.bundleIdentifier() else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = areaCache, cached.pid == app.processIdentifier, now < cached.expires { return cached.rect }
        let editor = AXIsProcessTrusted() ? CrossAppAccessibility.focusedEditor(in: app).flatMap(CrossAppAccessibility.frame) : nil
        let rect = editor ?? FocusedWindowFrame.frame(pid: app.processIdentifier)
        areaCache = (app.processIdentifier, rect, now + cacheLifetime)
        return rect
    }

    static func resetCaches() {
        caretCache = nil; areaCache = nil
    }
}

private struct IMKCorrectionClient: CorrectionClient {
    let client: any IMKTextInput
    func selectedRange() -> NSRange { client.selectedRange() }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? { client.attributedSubstring(from: range) }
    func insertText(_ string: String, replacementRange: NSRange) { client.insertText(string, replacementRange: replacementRange) }
    func insertAttributedText(_ text: NSAttributedString, replacementRange: NSRange) { client.insertText(text, replacementRange: replacementRange) }
    /// Exact IMK bounds, only from hosts that answer such queries.
    func textRect(for range: NSRange) -> NSRect? {
        let host = client.bundleIdentifier() ?? ""
        // Chromium answers range queries outside its cache with a synchronous
        // round trip to the page, stalling typing on both sides, and never
        // returns usable bounds. Stop asking hosts that have never answered.
        guard IMKRangeSupport.shouldQuery(host) else { return nil }
        let rect = imkRangeRect(range)
        IMKRangeSupport.record(host, answered: rect != nil)
        return rect
    }

    func resolveTextRect(for range: NSRange, text: String, lookup: WordBoundsLookup,
                         completion: @escaping (NSRect) -> Void) {
        if let rect = textRect(for: range) { completion(rect); return }
        let selection = client.selectedRange()
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == client.bundleIdentifier(),
              selection.location != NSNotFound, range.location != NSNotFound,
              NSMaxRange(range) <= NSMaxRange(selection) else { return }
        CrossAppAccessibility.prepare(app)
        AccessibleWordLocator.locate(word: text, trailing: NSMaxRange(selection) - NSMaxRange(range),
                                     pid: app.processIdentifier, lookup: lookup, completion: completion)
    }

    private func imkRangeRect(_ range: NSRange) -> NSRect? {
        var caretActual = NSRange(location: NSNotFound, length: 0)
        let reportedCaret = client.firstRect(forCharacterRange: client.selectedRange(), actualRange: &caretActual)
        let lineCaret = imkCaretRect()
        func calibrated(_ rect: NSRect) -> NSRect {
            CorrectionOverlayGeometry.calibratedRangeRect(rect, reportedCaret: reportedCaret, lineCaret: lineCaret)
        }
        var actual = NSRange(location: NSNotFound, length: 0)
        let rect = calibrated(client.firstRect(forCharacterRange: range, actualRange: &actual))
        if actual == range, rect.width > 1, CorrectionOverlayGeometry.isUsable(rect) { return rect }
        // Some hosts return useful geometry but omit actualRange. Query both
        // document endpoints, requiring the returned indices to match whenever
        // supplied. Hosts returning the same caret for every query are rejected.
        guard range.location != NSNotFound, range.length > 0,
              range.location <= Int.max - range.length else { return nil }
        var startActual = NSRange(location: NSNotFound, length: 0)
        var endActual = NSRange(location: NSNotFound, length: 0)
        let start = calibrated(client.firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: &startActual))
        let end = calibrated(client.firstRect(forCharacterRange: NSRange(location: NSMaxRange(range), length: 0), actualRange: &endActual))
        if (startActual.location == NSNotFound || startActual.location == range.location),
           (endActual.location == NSNotFound || endActual.location == NSMaxRange(range)),
           let bounds = CorrectionOverlayGeometry.rangeRect(start: start, end: end) { return bounds }
        // Some clients return the full bounds but leave actualRange unset. Accept
        // these only when they differ from the current insertion-point rectangle.
        return CorrectionOverlayGeometry.unreportedRangeRect(rect, actual: actual, caret: calibrated(reportedCaret))
    }

    func caretRect() -> NSRect? {
        imkCaretRect() ?? AccessibleWordBounds.caretRect(client: client)
    }
    func approximateAnchorRect() -> NSRect? { AccessibleWordBounds.approximateArea(client: client) }
    private func imkCaretRect() -> NSRect? {
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.height > 0, rect.height < 200,
              NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else { return nil }
        return rect
    }
}

/// Tracks which hosts answer IMK range-geometry queries. Main thread only.
enum IMKRangeSupport {
    static let attemptsBeforeSkipping = 3
    private static var record: [String: (answered: Int, unanswered: Int)] = [:]

    static func shouldQuery(_ host: String) -> Bool {
        guard let entry = record[host] else { return true }
        return entry.answered > 0 || entry.unanswered < attemptsBeforeSkipping
    }

    static func record(_ host: String, answered: Bool) {
        var entry = record[host] ?? (0, 0)
        if answered { entry.answered += 1 } else { entry.unanswered += 1 }
        record[host] = entry
    }

    static func reset() { record.removeAll() }
}

/// Keeps dictionary lookups off the key path. Deferred work runs on the main
/// thread, between key events.
protocol CorrectionScheduler: AnyObject {
    var now: TimeInterval { get }
    func isCached(_ word: String) -> Bool
    /// Look `word` up away from the main thread, then call `completion` on it.
    func lookUp(_ word: String, completion: @escaping () -> Void)
    /// Run `action` on the main thread after `delay`, replacing any earlier request.
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void)
}

final class BackgroundCorrectionScheduler: CorrectionScheduler {
    private var timer: Timer?
    deinit { timer?.invalidate() }
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func isCached(_ word: String) -> Bool { NativeSpellingCandidates.isCached(word) }
    func lookUp(_ word: String, completion: @escaping () -> Void) {
        NativeSpellingCandidates.prefetch(word, completion: completion)
    }
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        timer?.invalidate()
        let timer = Timer(timeInterval: max(0, delay), repeats: false) { _ in action() }
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }
}

/// A space whose correction is decided once typing pauses and the host's text
/// has settled. `distance` counts UTF-16 units from the separator to the caret.
private struct DeferredBoundary {
    let client: any CorrectionClient
    let separator: String
    var distance: Int
    /// The word typed before the separator, when it is known exactly.
    let token: String
    var attempts = 0
}

final class CorrectionSession {
    private var engine: FastCorrectionEngine
    private let personalization: PersonalizationStore
    private let protectedWords: ProtectedWords
    private var pendingSuggestion: (correction: FastCorrection, candidate: CorrectionCandidate, range: NSRange, caret: Int, generation: UInt64)?
    private var undoneSource: (source: String, replacement: String, context: String)?
    private(set) var presentationAnchor: CorrectionOverlayAnchor?
    var hasSuggestion: Bool { pendingSuggestion != nil }
    var onPresentation: ((SessionPresentation, any CorrectionClient) -> Bool)?
    var onHide: (() -> Void)?
    var onContinueTyping: ((CorrectionOverlayAnchor) -> Void)?
    /// A correction was reverted; its highlight no longer marks anything.
    var onUndo: (() -> Void)?

    init(personalization: PersonalizationStore = .shared, frequencyModel: WordFrequencyModel = .shared, protectedWords: ProtectedWords = .shared, phraseCandidateProvider: (([String]) -> [CorrectionCandidate])? = nil,
         rerankProvider: FastCorrectionEngine.RerankProvider? = ContextReranker.shared.decision) {
        self.personalization = personalization
        self.protectedWords = protectedWords
        NativeSpellingCandidates.useVocabulary(frequencyModel)
        engine = FastCorrectionEngine(
            candidateProvider: NativeSpellingCandidates.suggestions,
            suppressionProvider: { original, replacement in
                protectedWords.suppresses(original: original, replacement: replacement)
                    || personalization.shouldSuppress(original: original, replacement: replacement)
            },
            rerankProvider: rerankProvider,
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
            },
            spellingRanker: SpellingRanker(frequencies: frequencyModel, provider: NativeSpellingCandidates.cachedSuggestions).rank,
            rejectionProvider: { personalization.hasRejected(original: $0) },
            homophoneEvidence: { HomophoneGuard.evidence(left: $0, source: $1, replacement: $2, frequencies: frequencyModel) }
        )
    }
    private var recentCorrection: CorrectionLedger?
    // Retained only for the visible capsule, independently of immediate Backspace undo.
    private var visibleCorrection: CorrectionLedger?
    private var expectedCaretLocation: Int?
    private var needsContextSync = true
    var correctionsSuppressedForApp = false
    var usesNativeTyping = false

    /// When set, slow or uncertain boundaries are decided at the next pause in
    /// typing rather than while the space key waits. Nil keeps every decision
    /// synchronous, as the document tests expect.
    var scheduler: CorrectionScheduler?
    static let deferredIdleDelay: TimeInterval = 0.15
    static let deferredRetryDelay: TimeInterval = 0.12
    static let deferredAttempts = 4
    static let maximumDeferredDistance = 96
    private var deferred: [DeferredBoundary] = []
    private var lastKeyActivity: TimeInterval = -.infinity
    /// Text typed since the last space, independent of the host's reports.
    /// Chromium hosts can answer document queries before recent keys land.
    private var typedToken = ""
    private var typedTokenIsComplete = false
    var hasDeferredCorrections: Bool { !deferred.isEmpty }

    func finishSession() {
        acceptRecentCorrection()
        invalidateSession()
        personalization.flush()
    }

    /// Chrome must insert its own ordinary key events. Query/replace only at
    /// spaces, and always forward that original separator to the host afterwards.
    /// An unsupported client therefore still receives every typed character.
    func processNativeInput(_ string: String, client: any CorrectionClient) -> Bool {
        noteKeyActivity()
        acceptRecentCorrection()
        invalidateSession(preservingPresentation: visibleCorrection != nil, keepingDeferred: true)
        guard !correctionsSuppressedForApp else { invalidateSession(); return false }
        if string == " " {
            return processInput(string, client: client, commitsInput: false, tracksForwardedBoundary: true)
        }
        trackTyped(string)
        if !continueCorrectionFeedback(with: string, client: client) { invalidateSession(keepingDeferred: true) }
        return false
    }

    func processInput(_ string: String, client: any CorrectionClient, commitsInput: Bool = true,
                      tracksForwardedBoundary: Bool = false, consumesBoundaryOnCorrection: Bool = false) -> Bool {
        noteKeyActivity()
        let inputReceived = ContinuousClock.now
        discardSuggestion(.suggestionIgnored)
        undoneSource = nil
        if !continueCorrectionFeedback(with: string, client: client) { onHide?() }

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
        // Every remaining path inserts or forwards `string`.
        defer { trackTyped(string) }

        // Read the document before writing. IMK clients may report a stale caret
        // immediately after insertText, and replacing only the word after inserting
        // its space would put the caret before that space in native text views.
        let selection = client.selectedRange()
        if let deferral = deferral(for: string, commitsInput: commitsInput, forwards: tracksForwardedBoundary) {
            // Never make the space wait for a slow lookup or an unsettled host.
            engine.consumeWithoutCorrection(string)
            enqueueDeferred(separator: string, client: client, lookup: deferral.lookup)
            guard commitsInput else { return false }
            client.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
            expectedCaretLocation = selection.location == NSNotFound ? nil : selection.location + (string as NSString).length
            return true
        }
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
                    // The host has not caught up with recent keys. Decide again
                    // from its settled text once typing pauses.
                    invalidateSession(preservingPresentation: visibleCorrection != nil, keepingDeferred: true)
                    if scheduler != nil, string == " ", commitsInput || tracksForwardedBoundary {
                        enqueueDeferred(separator: string, client: client, lookup: nil)
                    }
                    if commitsInput { client.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0)) }
                    return commitsInput
                }
                engine.locateCandidate(in: sourceRange)
                // Replace the word and commit its separator in one transaction.
                client.insertText(correction.replacement + (commitsInput ? correction.suffix : existingSuffix), replacementRange: replacementRange)
                advanceDeferred(by: correction.replacementUTF16Length - correction.originalUTF16Length)
                if !commitsInput && !tracksForwardedBoundary && !consumesBoundaryOnCorrection {
                    invalidateSession()
                    return false
                }
                PerformanceRecorder.shared.recordReplacement(startedAt: inputReceived)
                let retainedSuffix = consumesBoundaryOnCorrection ? existingSuffix : correction.suffix
                let correctedText = correction.replacement + retainedSuffix
                let expectedCaret = sourceRange.location + (correctedText as NSString).length
                recentCorrection = CorrectionLedger(
                    generation: engine.generation,
                    range: NSRange(location: sourceRange.location, length: (correctedText as NSString).length),
                    original: correction.original,
                    correctedText: correctedText,
                    replacement: correction.replacement,
                    suffix: retainedSuffix,
                    expectedCaretLocation: expectedCaret,
                    candidate: engine.lastCandidate
                )
                visibleCorrection = recentCorrection
                expectedCaretLocation = expectedCaret
                presentationAnchor = CorrectionOverlayAnchor(range: NSRange(location: sourceRange.location, length: correction.replacementUTF16Length), text: correction.replacement, caret: expectedCaret)
                if onPresentation?(.corrected(correction), client) == false { visibleCorrection = nil }
                return commitsInput || consumesBoundaryOnCorrection
            }
            invalidateSession(preservingPresentation: visibleCorrection != nil, keepingDeferred: true)
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
            visibleCorrection = nil
            pendingSuggestion = (suggestion, candidate, range, caret, engine.generation)
            presentationAnchor = CorrectionOverlayAnchor(range: range, text: suggestion.original, caret: caret)
            if onPresentation?(.suggestion(suggestion), client) == false { pendingSuggestion = nil }
        }
        return true
    }

    func didCommand(_ command: String, client: any CorrectionClient) -> Bool {
        noteKeyActivity()
        if command == "insertTab:", hasSuggestion { return acceptSuggestion(in: client) }
        if command == "cancelOperation:", hasSuggestion {
            dismissPresentation(client: client); return true
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
            // Retire any earlier correction so only an edit made by this Tab
            // consumes the key. Shift-Tab retains backward focus navigation.
            acceptRecentCorrection()
            _ = processInput("\t", client: client, commitsInput: false,
                consumesBoundaryOnCorrection: command == "insertTab:")
            if command == "insertTab:", recentCorrection != nil { return true }
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
        if command == "deleteBackward:" {
            // Pending decisions survive edits to the text typed after them;
            // each is revalidated against the document before it applies.
            advanceDeferred(by: -1)
            deferred.removeAll { $0.distance < ($0.separator as NSString).length }
            if typedToken.isEmpty { typedTokenIsComplete = false } else { typedToken.removeLast() }
            invalidateSession(keepingDeferred: true)
            return false
        }
        invalidateSession()
        return false
    }

    /// Keep the capsule actionable while ordinary typing appends after its word.
    /// Store and validate the exact trailing text so undo preserves everything typed.
    private func continueCorrectionFeedback(with string: String, client: any CorrectionClient) -> Bool {
        guard let correction = visibleCorrection, string.count == 1,
              !string.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              Self.isTypingAfter(correction, selection: client.selectedRange(),
                                 settled: text(in: correction.range, from: client) == correction.correctedText) else {
            visibleCorrection = nil
            return false
        }
        let length = (string as NSString).length
        let caret = correction.expectedCaretLocation + length
        visibleCorrection = CorrectionLedger(generation: correction.generation,
            range: NSRange(location: correction.range.location, length: correction.range.length + length),
            original: correction.original, correctedText: correction.correctedText + string,
            replacement: correction.replacement, suffix: correction.suffix + string,
            expectedCaretLocation: caret, candidate: correction.candidate, wasSuggestion: correction.wasSuggestion)
        let anchor = CorrectionOverlayAnchor(range: NSRange(location: correction.range.location,
            length: (correction.replacement as NSString).length), text: correction.replacement, caret: caret)
        presentationAnchor = anchor
        onContinueTyping?(anchor)
        return true
    }

    /// Whether a key typed now continues after the visible correction. Hosts
    /// that apply insertions asynchronously (Electron, Chromium) can still
    /// report the caret inside the separator or the replaced range itself, so
    /// any selection ending between the replacement and the expected caret is
    /// accepted. Undo validates the exact text and caret before writing.
    private static func isTypingAfter(_ correction: CorrectionLedger, selection: NSRange, settled: Bool) -> Bool {
        let expected = NSRange(location: correction.expectedCaretLocation, length: 0)
        if selection == expected && settled { return true }
        let replacementEnd = correction.range.location + (correction.replacement as NSString).length
        guard selection.location != NSNotFound, selection.location >= correction.range.location,
              selection.length <= correction.range.length,
              selection.location <= Int.max - selection.length else { return false }
        return NSMaxRange(selection) >= replacementEnd && NSMaxRange(selection) <= expected.location
    }

    @discardableResult func undoCorrection(in client: any CorrectionClient) -> Bool {
        guard let correction = visibleCorrection else { return didCommand("undo:", client: client) }
        let selection = client.selectedRange()
        guard selection == NSRange(location: correction.expectedCaretLocation, length: 0),
              text(in: correction.range, from: client) == correction.correctedText,
              client.selectedRange() == selection else { invalidateSession(); return false }
        // Reuse the validated restore path with the current engine generation.
        recentCorrection = CorrectionLedger(generation: engine.generation, range: correction.range,
            original: correction.original, correctedText: correction.correctedText,
            replacement: correction.replacement, suffix: correction.suffix,
            expectedCaretLocation: correction.expectedCaretLocation, candidate: correction.candidate,
            wasSuggestion: correction.wasSuggestion)
        return restoreRecentCorrection(in: client, removingSuffix: false)
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
        onUndo?()
        personalization.record(correction.wasSuggestion ? .suggestionRejected : .automaticUndone,
            original: correction.original, replacement: correction.replacement,
            context: correction.candidate?.contextSignature ?? "")
        recentCorrection = nil
        visibleCorrection = nil
        invalidateSession(preservingPresentation: true)
        expectedCaretLocation = correction.range.location + (restored as NSString).length
        undoneSource = (correction.original, correction.replacement, correction.candidate?.contextSignature ?? "")
        presentationAnchor = CorrectionOverlayAnchor(range: NSRange(location: correction.range.location, length: (correction.original as NSString).length), text: correction.original, caret: expectedCaretLocation!)
        if personalization.shouldOfferAlwaysKeep(original: correction.original) {
            _ = onPresentation?(.keep(correction.original), client)
        } else { onHide?() }
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
            // Usually a host that has not caught up; deferred spaces revalidate.
            // Keep visible feedback: continued typing was already checked above.
            invalidateSession(preservingPresentation: visibleCorrection != nil, keepingDeferred: true)
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
        visibleCorrection = recentCorrection
        expectedCaretLocation = caret
        presentationAnchor = CorrectionOverlayAnchor(range: NSRange(location: fullRange.location, length: correction.replacementUTF16Length), text: correction.replacement, caret: caret)
        if onPresentation?(.corrected(correction), client) == false { visibleCorrection = nil }
        return true
    }

    @discardableResult func alwaysKeep(client: (any CorrectionClient)? = nil) -> Bool {
        guard let source = undoneSource else { return false }
        if let client, let anchor = presentationAnchor {
            let selection = client.selectedRange()
            guard selection == NSRange(location: anchor.caret, length: 0),
                  text(in: anchor.range, from: client) == anchor.text,
                  client.selectedRange() == selection else { invalidateSession(); return false }
        }
        let tokens = source.source.split(separator: " ").map(String.init)
        if tokens.count == 1 {
            guard protectedWords.protect(source.source) else { return false }
            personalization.observeIntentional(source.source)
        } else {
            // Explicit phrase suppression never whitelists incidental neighbours.
            personalization.suppressPair(original: source.source, replacement: source.replacement, context: source.context)
        }
        personalization.flush()
        undoneSource = nil
        if let client { _ = onPresentation?(.learned(source.source), client) }
        else { onHide?() }
        return true
    }

    func expirePresentation() {
        visibleCorrection = nil
        discardSuggestion(.suggestionIgnored); undoneSource = nil; onHide?()
    }

    func dismissPresentation(client: (any CorrectionClient)? = nil) {
        visibleCorrection = nil
        let rejected = pendingSuggestion
        discardSuggestion(.suggestionRejected); undoneSource = nil; onHide?()
        if let rejected, let client,
           personalization.shouldOfferAlwaysKeep(original: rejected.correction.original) {
            let source = rejected.correction.original
            undoneSource = (source, rejected.correction.replacement, rejected.candidate.contextSignature)
            presentationAnchor = CorrectionOverlayAnchor(range: rejected.range, text: source, caret: rejected.caret)
            _ = onPresentation?(.keep(source), client)
        }
    }

    private func discardSuggestion(_ interaction: PersonalInteraction) {
        guard let pending = pendingSuggestion else { return }
        personalization.record(interaction, original: pending.correction.original,
            replacement: pending.correction.replacement, context: pending.candidate.contextSignature)
        pendingSuggestion = nil
    }

    /// `keepingDeferred` is for refreshes during ordinary typing. Navigation,
    /// clicks, Enter and other commands drop pending decisions.
    func invalidateSession(preservingPresentation: Bool = false, keepingDeferred: Bool = false) {
        discardSuggestion(.suggestionIgnored)
        undoneSource = nil
        if !preservingPresentation { visibleCorrection = nil; presentationAnchor = nil; onHide?() }
        engine.invalidate()
        recentCorrection = nil
        expectedCaretLocation = nil
        needsContextSync = true
        if !keepingDeferred {
            deferred.removeAll()
            typedToken = ""; typedTokenIsComplete = false
        }
    }

    // MARK: Deferred boundaries

    private func noteKeyActivity() {
        guard let scheduler else { return }
        lastKeyActivity = scheduler.now
        requestFlush()
    }

    private func trackTyped(_ string: String) {
        advanceDeferred(by: (string as NSString).length)
        if string.contains(where: \.isWhitespace) {
            typedToken = ""; typedTokenIsComplete = true
        } else if typedToken.count + string.count <= FastCorrectionEngine.maximumWordLength * 2 {
            typedToken += string
        } else {
            typedToken = ""; typedTokenIsComplete = false
        }
    }

    private func advanceDeferred(by delta: Int) {
        guard !deferred.isEmpty else { return }
        for index in deferred.indices { deferred[index].distance += delta }
        deferred.removeAll { $0.distance < 0 || $0.distance > Self.maximumDeferredDistance }
    }

    /// A space waits when its dictionary lookup is not cached, or when the
    /// engine's word disagrees with what was typed because the host lags.
    private struct Deferral { let lookup: String? }

    private func deferral(for string: String, commitsInput: Bool, forwards: Bool) -> Deferral? {
        guard let scheduler, string == " ", commitsInput || forwards else { return nil }
        let token = engine.pendingToken
        let consistent = typedTokenIsComplete
            ? token == String(typedToken.drop(while: { !$0.isLetter }))
            : token.hasSuffix(typedToken)
        if !consistent {
            let word = String(typedToken.drop(while: { !$0.isLetter })
                .prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" })).lowercased()
            return Deferral(lookup: word.isEmpty || scheduler.isCached(word) ? nil : word)
        }
        if let key = engine.boundaryLookupKey, !scheduler.isCached(key) { return Deferral(lookup: key) }
        return nil
    }

    private func enqueueDeferred(separator: String, client: any CorrectionClient, lookup: String?) {
        if deferred.count >= 8 { deferred.removeFirst() }
        deferred.append(DeferredBoundary(client: client, separator: separator, distance: 0,
            token: typedTokenIsComplete ? typedToken : ""))
        if let lookup, let scheduler {
            scheduler.lookUp(lookup) { [weak self] in self?.requestFlush() }
        }
        requestFlush()
    }

    private func requestFlush(after minimum: TimeInterval = 0) {
        guard let scheduler, !deferred.isEmpty else { return }
        let idle = lastKeyActivity + Self.deferredIdleDelay - scheduler.now
        scheduler.schedule(after: max(minimum, idle)) { [weak self] in self?.flushDeferred() }
    }

    private enum DeferredOutcome { case finished, waiting, unsettled }

    /// Apply pending spaces in document order, only while typing is paused,
    /// so no edit races keys the host has not processed yet.
    func flushDeferred() {
        guard let scheduler else { return }
        guard scheduler.now - lastKeyActivity >= Self.deferredIdleDelay - 0.01 else { requestFlush(); return }
        while let item = deferred.first {
            let outcome = applyDeferred(item, scheduler: scheduler)
            if outcome == .finished { deferred.removeFirst(); continue }
            deferred[0].attempts += 1
            if deferred[0].attempts >= Self.deferredAttempts { deferred.removeFirst(); continue }
            // A lookup's completion requests the next flush itself.
            if outcome == .unsettled { requestFlush(after: Self.deferredRetryDelay) }
            return
        }
    }

    private func applyDeferred(_ item: DeferredBoundary, scheduler: CorrectionScheduler) -> DeferredOutcome {
        guard !correctionsSuppressedForApp else { return .finished }
        let client = item.client
        let selection = client.selectedRange()
        guard selection.location != NSNotFound, selection.length == 0,
              let located = locate(item, caret: selection.location, client: client) else { return .unsettled }
        // Rebuild the decision from the settled document, including whether
        // the word starts a sentence.
        var replay = engine
        replay.synchronize(leftContext: located.context)
        replay.consumeWithoutCorrection(located.token)
        if let key = replay.boundaryLookupKey, !scheduler.isCached(key) {
            scheduler.lookUp(key) { [weak self] in self?.requestFlush() }
            return .waiting
        }
        let correction = replay.consume(item.separator)
        if let correction {
            let expected = correction.original + correction.suffix
            let start = located.separatorEnd - (expected as NSString).length
            guard start >= 0 else { return .finished }
            let range = NSRange(location: start, length: selection.location - start)
            guard let current = client.attributedSubstring(from: range), current.length == range.length,
                  (current.string as NSString).hasPrefix(expected),
                  client.selectedRange() == selection else { return .unsettled }
            // Text typed after the space is rewritten unchanged with its
            // attributes, so the caret stays after it.
            let trailing = (current.string as NSString).substring(from: (expected as NSString).length)
            let corrected = NSMutableAttributedString(attributedString: current)
            corrected.replaceCharacters(in: NSRange(location: 0, length: correction.originalUTF16Length), with: correction.replacement)
            client.insertAttributedText(corrected, replacementRange: range)
            invalidateSession(keepingDeferred: true)
            replay.locateCandidate(in: NSRange(location: start, length: correction.originalUTF16Length))
            let correctedText = correction.replacement + correction.suffix + trailing
            let caret = start + (correctedText as NSString).length
            let ledger = CorrectionLedger(generation: engine.generation,
                range: NSRange(location: start, length: (correctedText as NSString).length),
                original: correction.original, correctedText: correctedText, replacement: correction.replacement,
                suffix: correction.suffix + trailing, expectedCaretLocation: caret, candidate: replay.lastCandidate)
            // Immediate Backspace restores only while nothing follows the space.
            if trailing.isEmpty { recentCorrection = ledger }
            visibleCorrection = ledger
            expectedCaretLocation = caret
            presentationAnchor = CorrectionOverlayAnchor(range: NSRange(location: start, length: correction.replacementUTF16Length),
                text: correction.replacement, caret: caret)
            if onPresentation?(.corrected(correction), client) == false { visibleCorrection = nil }
            return .finished
        }
        // Suggestions wait for Tab, so offer one only while the caret is still after its space.
        if let suggestion = replay.suggestion, var candidate = replay.lastCandidate,
           selection.location == located.separatorEnd {
            let expected = suggestion.original + suggestion.suffix
            let start = located.separatorEnd - (expected as NSString).length
            guard start >= 0, text(in: NSRange(location: start, length: (expected as NSString).length), from: client) == expected,
                  client.selectedRange() == selection else { return .finished }
            let range = NSRange(location: start, length: suggestion.originalUTF16Length)
            candidate.sourceRange = range
            visibleCorrection = nil
            pendingSuggestion = (suggestion, candidate, range, selection.location, engine.generation)
            presentationAnchor = CorrectionOverlayAnchor(range: range, text: suggestion.original, caret: selection.location)
            if onPresentation?(.suggestion(suggestion), client) == false { pendingSuggestion = nil }
        }
        return .finished
    }

    /// Find the deferred space by its distance from the caret, falling back to
    /// the typed word nearest the caret. Both must match the document exactly.
    private func locate(_ item: DeferredBoundary, caret: Int, client: any CorrectionClient)
        -> (context: String?, token: String, separatorEnd: Int)? {
        let separatorLength = (item.separator as NSString).length
        func located(separatorStart: Int) -> (context: String?, token: String, separatorEnd: Int)? {
            let separatorEnd = separatorStart + separatorLength
            guard separatorStart > 0, separatorEnd <= caret,
                  let tail = text(in: NSRange(location: separatorStart, length: caret - separatorStart), from: client),
                  tail.hasPrefix(item.separator), tail.rangeOfCharacter(from: .newlines) == nil else { return nil }
            let windowLength = min(separatorStart, FastCorrectionEngine.maximumWordLength * 2 + 2)
            guard let window = text(in: NSRange(location: separatorStart - windowLength, length: windowLength), from: client) else { return nil }
            let characters = window as NSString
            let whitespace = characters.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards)
            // A token longer than the window is not a word Cappy corrects.
            guard whitespace.location != NSNotFound || windowLength == separatorStart else { return nil }
            let tokenOffset = whitespace.location == NSNotFound ? 0 : NSMaxRange(whitespace)
            let token = characters.substring(from: tokenOffset)
            guard !token.isEmpty else { return nil }
            let tokenStart = separatorStart - windowLength + tokenOffset
            let contextLength = min(tokenStart, FastCorrectionEngine.maximumContextUTF16Length)
            let context = contextLength == 0 ? ""
                : text(in: NSRange(location: tokenStart - contextLength, length: contextLength), from: client)
            return (context, token, separatorEnd)
        }
        if let result = located(separatorStart: caret - item.distance),
           item.token.isEmpty || result.token == item.token { return result }
        guard !item.token.isEmpty else { return nil }
        let needle = item.token + item.separator
        let windowLength = min(caret, Self.maximumDeferredDistance + (needle as NSString).length)
        guard let window = text(in: NSRange(location: caret - windowLength, length: windowLength), from: client) else { return nil }
        var searchRange = NSRange(location: 0, length: (window as NSString).length)
        while true {
            let match = (window as NSString).range(of: needle, options: .backwards, range: searchRange)
            guard match.location != NSNotFound else { return nil }
            let separatorStart = caret - windowLength + NSMaxRange(match) - separatorLength
            if let result = located(separatorStart: separatorStart), result.token == item.token { return result }
            searchRange.length = match.location
        }
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

    /// Uncached lookups take 5–150 ms. All spell-checker access is serialized
    /// here so typing can prefetch off the main thread.
    private static let queue = DispatchQueue(label: "com.efekoy.inputmethod.Cappy.spelling", qos: .userInitiated)
    /// Read only on `queue`.
    private static var vocabulary: WordFrequencyModel?

    static func useVocabulary(_ model: WordFrequencyModel) {
        guard model.isAvailable else { return }
        queue.async { if vocabulary == nil { vocabulary = model } }
    }

    static func cachedSuggestions(for word: String) -> [String] {
        cache.object(forKey: word as NSString) as? [String] ?? []
    }

    static func isCached(_ word: String) -> Bool {
        cache.object(forKey: word as NSString) != nil
    }

    /// Look `word` up on the spelling queue, then call `completion` on the main thread.
    static func prefetch(_ word: String, completion: @escaping () -> Void) {
        queue.async {
            if !isCached(word) { _ = lookUp(word) }
            DispatchQueue.main.async(execute: completion)
        }
    }

    static func alternatives(for word: String) -> [String] {
        if let cached = alternativesCache.object(forKey: word as NSString) as? [String] { return cached }
        let result = queue.sync {
            NSSpellChecker.shared.guesses(
                forWordRange: NSRange(location: 0, length: (word as NSString).length),
                in: word, language: "en_GB", inSpellDocumentWithTag: 0
            ) ?? []
        }
        alternativesCache.setObject(result as NSArray, forKey: word as NSString)
        return result
    }

    static func prepare() {
        // Create the shared checker on the main thread before any prefetch.
        let checker = NSSpellChecker.shared
        queue.sync {
            _ = checker.checkSpelling(
                of: "cappy",
                startingAt: 0,
                language: "en_GB",
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )
        }
    }

    static func suggestions(for word: String) -> [String] {
        if let cached = cache.object(forKey: word as NSString) as? [String] {
            return cached
        }
        return queue.sync { lookUp(word) }
    }

    /// Runs on `queue` only.
    private static func lookUp(_ word: String) -> [String] {
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
        // The dictionary offers nothing for typos several letters off, such as
        // “defitnetaly”. Offer close common corpus words it recognises.
        if suggestions.isEmpty, preferred == nil, let vocabulary {
            suggestions = vocabulary.closeWords(to: word).filter {
                checker.checkSpelling(of: $0, startingAt: 0, language: "en_GB", wrap: false,
                                      inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
            }
        }
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
        if modifiers.intersection([.command, .control, .option, .shift]) == [.control, .option],
           event.keyCode == UInt16(kVK_ANSI_Z) {
            reset()
            return session.undoCorrection(in: client)
        }
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
