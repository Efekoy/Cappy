import AppKit
import SwiftUI
import QuartzCore
import ApplicationServices
import os

private final class CorrectionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The session supplies document offsets, never a selection or marked-text span.
struct CorrectionOverlayAnchor: Equatable {
    let range: NSRange
    let text: String
    let caret: Int

    /// The whole words of this replacement that differ from `original`, so
    /// a phrase fix such as “I have multple” → “I have multiple” highlights
    /// only “multiple”. Capitalisation and apostrophe changes don't count,
    /// and a fix made only of them, such as “i dont” → “I don't”, returns nil
    /// so no box is drawn. Pure deletions keep the whole anchor.
    func changedWords(from original: String) -> CorrectionOverlayAnchor? {
        guard !Self.isCosmetic(original, text) else { return nil }
        let source = original as NSString, replacement = text as NSString
        guard replacement.length == range.length else { return self }
        func isSpace(_ string: NSString, _ index: Int) -> Bool {
            CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(string.character(at: index)) ?? " ")
        }
        func words(_ string: NSString) -> [NSRange] {
            var ranges: [NSRange] = [], start: Int?
            for index in 0...string.length {
                if index < string.length, !isSpace(string, index) { start = start ?? index; continue }
                if let first = start { ranges.append(NSRange(location: first, length: index - first)); start = nil }
            }
            return ranges
        }
        let sourceWords = words(source), replacementWords = words(replacement)
        var start: Int, end: Int
        if sourceWords.count == replacementWords.count {
            let changed = replacementWords.indices.filter {
                !Self.isCosmetic(source.substring(with: sourceWords[$0]), replacement.substring(with: replacementWords[$0]))
            }
            guard let first = changed.first, let last = changed.last else { return nil }
            start = replacementWords[first].location; end = NSMaxRange(replacementWords[last])
        } else {
            let shorter = min(source.length, replacement.length)
            var prefix = 0
            while prefix < shorter, source.character(at: prefix) == replacement.character(at: prefix) { prefix += 1 }
            var suffix = 0
            while suffix < shorter - prefix,
                  source.character(at: source.length - 1 - suffix) == replacement.character(at: replacement.length - 1 - suffix) { suffix += 1 }
            start = prefix; end = replacement.length - suffix
            while start > 0, !isSpace(replacement, start - 1) { start -= 1 }
            while end < replacement.length, !isSpace(replacement, end) { end += 1 }
        }
        guard end > start, end - start < replacement.length else { return self }
        return CorrectionOverlayAnchor(range: NSRange(location: range.location + start, length: end - start),
                                       text: replacement.substring(with: NSRange(location: start, length: end - start)), caret: caret)
    }

    /// True when `original` and `replacement` differ only in capitalisation
    /// or apostrophes, such as “im” → “I'm” or “dont” → “don’t”.
    static func isCosmetic(_ original: String, _ replacement: String) -> Bool {
        func key(_ text: String) -> String { text.lowercased().filter { !"'’‘".contains($0) } }
        return key(original) == key(replacement)
    }
}

enum CorrectionOverlayState: Equatable {
    case hidden, automaticCorrection, suggestion, undoLearning, learnedConfirmation
}

/// Pure transition model, shared by the native presentation and regression tests.
struct CorrectionOverlayMachine {
    private(set) var state: CorrectionOverlayState = .hidden
    private(set) var revision = 0
    var duration: TimeInterval {
        switch state {
        case .hidden: return 0
        case .automaticCorrection: return 2.5
        case .suggestion, .undoLearning: return 5
        case .learnedConfirmation: return 0.9
        }
    }
    mutating func present(_ presentation: SessionPresentation) {
        revision += 1
        switch presentation {
        case .corrected: state = .automaticCorrection
        case .suggestion: state = .suggestion
        case .keep: state = .undoLearning
        case .learned: state = .learnedConfirmation
        }
    }
    mutating func hide() { revision += 1; state = .hidden }
    mutating func expire(revision expected: Int) -> Bool {
        guard revision == expected, state != .hidden else { return false }
        hide(); return true
    }
}

enum CorrectionOverlayGeometry {
    static func isUsable(_ rect: NSRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width >= 0 && rect.width < 1600 && rect.height > 0 && rect.height < 200
    }
    /// Hosts sometimes omit actualRange. Distinct narrow endpoint rectangles
    /// can still establish a precise single-line range without estimating fonts.
    static func rangeRect(start: NSRect, end: NSRect) -> NSRect? {
        guard isUsable(start), isUsable(end), start.width <= 2, end.width <= 2,
              abs(start.minY - end.minY) <= 1, abs(start.height - end.height) <= 1,
              end.minX - start.minX > 1 else { return nil }
        return NSRect(x: start.minX, y: start.minY, width: end.minX - start.minX, height: start.height)
    }

    /// IMK proxies can report a range using the caret's upper edge while the
    /// line-height query uses its lower edge. Calibrate against the same caret,
    /// rather than applying a fixed offset to every app or every screen.
    static func calibratedRangeRect(_ rect: NSRect, reportedCaret: NSRect, lineCaret: NSRect?) -> NSRect {
        guard let lineCaret, isUsable(rect), isUsable(reportedCaret), isUsable(lineCaret),
              reportedCaret.width <= 2, lineCaret.width <= 2,
              abs(reportedCaret.minX - lineCaret.minX) <= 2 else { return rect }
        let deltaY = lineCaret.minY - reportedCaret.minY
        guard abs(deltaY) <= max(reportedCaret.height, lineCaret.height) * 1.5 else { return rect }
        return rect.offsetBy(dx: 0, dy: deltaY)
    }

    static func unreportedRangeRect(_ rect: NSRect, actual: NSRange, caret: NSRect) -> NSRect? {
        guard actual.location == NSNotFound, isUsable(rect), rect.width > 2,
              isUsable(caret), caret.width <= 2,
              rect.minX < caret.minX - 1 || abs(rect.minY - caret.minY) > 1 else { return nil }
        return rect
    }

    /// True when a reported text rectangle is really its element's frame.
    static func isWholeElement(_ rect: NSRect, frame: NSRect) -> Bool {
        abs(rect.minX - frame.minX) <= 1 && abs(rect.minY - frame.minY) <= 1
            && abs(rect.width - frame.width) <= 1 && abs(rect.height - frame.height) <= 1
    }

    /// The screen showing most of `rect`. Partial overlap is enough: carets
    /// near the Dock or menu bar sit outside the visible frame.
    static func screen(for rect: NSRect, in screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        let probe = rect.width < 1 ? rect.insetBy(dx: -0.5, dy: 0) : rect
        return screens.map { ($0, $0.frame.intersection(probe)) }
            .filter { !$0.1.isNull }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
    }

    /// Placement when only the editor or window is known. A field-sized area
    /// is treated like a word; a larger one gets the capsule inside its
    /// lower-left corner rather than beyond its edge.
    static func approximateCapsuleFrame(area: NSRect, size: NSSize, screen: NSRect) -> NSRect {
        guard area.height > 160 else { return capsuleFrame(anchor: area, size: size, screen: screen) }
        let visible = area.intersection(screen).isNull ? screen : area.intersection(screen)
        let x = min(max(visible.minX + 12, screen.minX), screen.maxX - size.width)
        let y = min(max(visible.minY + 12, screen.minY), screen.maxY - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    static func capsuleFrame(anchor: NSRect, size: NSSize, screen: NSRect) -> NSRect {
        let x = min(max(anchor.minX, screen.minX), screen.maxX - size.width)
        let below = anchor.minY - size.height - 5
        let y = below >= screen.minY ? below : min(anchor.maxY + 5, screen.maxY - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}

/// Borderless blue fill with iOS-style selection handles: a line at each end
/// of the word, with a dot above the start and below the end. Shared by
/// correction and suggestion highlights.
enum CorrectionHighlightStyle {
    static let cornerRadius: CGFloat = 2.5
    static let padding = NSSize(width: 2.5, height: 1.5)
    static let handleWidth: CGFloat = 2
    static let knobDiameter: CGFloat = 8.5
    /// Room around the box for the handles' dots, so they are not clipped.
    static let handleMargin = NSSize(width: knobDiameter / 2 + 1, height: knobDiameter + 1)

    /// The padded box around the text.
    static func box(around rect: NSRect) -> NSRect {
        rect.insetBy(dx: -padding.width, dy: -padding.height)
    }

    /// The window frame: the box plus room for the handles.
    static func frame(around rect: NSRect) -> NSRect {
        box(around: rect).insetBy(dx: -handleMargin.width, dy: -handleMargin.height)
    }

    static func makeView() -> NSView { CorrectionHighlightView() }
}

private final class CorrectionHighlightView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let margin = CorrectionHighlightStyle.handleMargin
        let box = bounds.insetBy(dx: margin.width, dy: margin.height)
        guard box.width > 0, box.height > 0 else { return }
        NSColor.systemBlue.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: box, xRadius: CorrectionHighlightStyle.cornerRadius,
                     yRadius: CorrectionHighlightStyle.cornerRadius).fill()
        NSColor.systemBlue.setFill()
        let line = CorrectionHighlightStyle.handleWidth, knob = CorrectionHighlightStyle.knobDiameter
        // Start handle: the dot sits above the text; end handle: below it.
        NSBezierPath(roundedRect: NSRect(x: box.minX - line / 2, y: box.minY, width: line, height: box.height),
                     xRadius: line / 2, yRadius: line / 2).fill()
        NSBezierPath(ovalIn: NSRect(x: box.minX - knob / 2, y: box.maxY - 1, width: knob, height: knob)).fill()
        NSBezierPath(roundedRect: NSRect(x: box.maxX - line / 2, y: box.minY, width: line, height: box.height),
                     xRadius: line / 2, yRadius: line / 2).fill()
        NSBezierPath(ovalIn: NSRect(x: box.maxX - knob / 2, y: box.minY - knob + 1, width: knob, height: knob)).fill()
    }
}

/// A host can apply insertText asynchronously. Never draw unmatched text, but
/// allow a short insertion grace period before dropping a new highlight.
/// Electron hosts can take longer, and can briefly report stale text while
/// later keys land, so only a mismatch that persists drops the highlight.
/// It is never drawn while the text differs.
struct CorrectionHighlightValidation {
    static let insertionGrace: TimeInterval = 1
    static let mismatchTolerance: TimeInterval = 0.8
    private(set) var hasMatched = false
    private var mismatchSince: TimeInterval?
    mutating func keep(age: TimeInterval, textMatches: Bool) -> Bool {
        guard age < 3 else { return false }
        if textMatches { hasMatched = true; mismatchSince = nil; return true }
        guard hasMatched else { return age < Self.insertionGrace }
        let since = mismatchSince ?? age
        mismatchSince = since
        return age - since < Self.mismatchTolerance
    }
}

/// Correction feedback outlives the actionable capsule while typing continues.
/// Each span is revalidated before drawing; no document formatting is changed.
private final class CorrectedWordHighlights {
    private struct Highlight {
        let client: any CorrectionClient
        let anchor: CorrectionOverlayAnchor
        let window: CorrectionPanel
        let started: TimeInterval
        let lookup: WordBoundsLookup
        var validation = CorrectionHighlightValidation()
        var visible = false
        var fading = false
        /// Exact, from the host; fixed once known.
        var frame: NSRect?
    }
    private var highlights: [Highlight] = []
    private var timer: Timer?
    private let duration: TimeInterval = 3
    /// Fades run on Core Animation at display rate; stepping alpha from the
    /// 0.12 s tracking timer looked like a low frame rate.
    private let fadeIn: TimeInterval = 0.08
    private let fadeOut: TimeInterval = 0.35
    /// Poll quickly until a highlight first appears, so it shows as soon as
    /// geometry exists; then the slower rate is enough to follow the text.
    private let fastInterval: TimeInterval = 0.03
    private let trackingInterval: TimeInterval = 0.12
    /// Time since the last key before Cappy queries the host again.
    static let typingQuiet: TimeInterval = 0.15

    deinit { timer?.invalidate() }

    /// `placed` receives the word's exact bounds once the host supplies them.
    func show(client: any CorrectionClient, anchor: CorrectionOverlayAnchor, placed: @escaping (NSRect) -> Void = { _ in }) {
        let window = CorrectionPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .popUpMenu
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.contentView = CorrectionHighlightStyle.makeView()
        // One box at a time: a new correction retires the previous box.
        dismiss(animated: true)
        let lookup = WordBoundsLookup()
        highlights.append(Highlight(client: client, anchor: anchor, window: window,
            started: ProcessInfo.processInfo.systemUptime, lookup: lookup))
        client.resolveTextRect(for: anchor.range, text: anchor.text, lookup: lookup) { [weak self] rect in
            guard let self, CorrectionOverlayGeometry.isUsable(rect), rect.width > 1,
                  CorrectionOverlayGeometry.screen(for: rect) != nil,
                  let index = self.highlights.firstIndex(where: { $0.lookup === lookup }) else { return }
            self.highlights[index].frame = CorrectionHighlightStyle.frame(around: rect)
            window.setFrame(self.highlights[index].frame!, display: true)
            placed(rect)
            self.update()
        }
        update()
    }

    func clear() { dismiss(animated: false) }

    private func dismiss(animated: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for highlight in highlights {
            highlight.lookup.cancel()
            let window = highlight.window
            guard animated, highlight.visible, !reduceMotion else { window.orderOut(nil); continue }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                window.animator().alphaValue = 0
            }, completionHandler: { window.orderOut(nil) })
        }
        highlights.removeAll()
        timer?.invalidate(); timer = nil
    }

    private func update() {
        let now = ProcessInfo.processInfo.systemUptime
        // Every document query is a synchronous round trip into the host.
        // While keys are arriving, make none: Electron answers on its main
        // thread, so querying then slows typing in the host itself.
        let typing = !TypingActivity.isQuiet(for: Self.typingQuiet, now: now)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        highlights = highlights.compactMap { original in
            var highlight = original
            let age = now - highlight.started
            guard age < duration else { highlight.lookup.cancel(); highlight.window.orderOut(nil); return nil }
            if typing { return highlight }
            let matches = highlight.client.attributedSubstring(from: highlight.anchor.range)?.string == highlight.anchor.text
            guard highlight.validation.keep(age: age, textMatches: matches) else {
                highlight.lookup.cancel(); highlight.window.orderOut(nil)
                return nil
            }
            guard matches else { highlight.window.orderOut(nil); highlight.visible = false; return highlight }
            // Exact bounds arrive from the host when it has them; until then,
            // and in hosts that never supply them, there is no box.
            guard highlight.frame != nil else { return highlight }
            // Once fading out, a highlight hidden by a stale read stays hidden.
            if !highlight.visible, !highlight.fading {
                highlight.visible = true
                highlight.window.alphaValue = reduceMotion ? 1 : 0
                highlight.window.orderFrontRegardless()
                if !reduceMotion { animateAlpha(highlight.window, to: 1, over: fadeIn) }
            }
            let remaining = duration - age
            if !highlight.fading, remaining <= fadeOut {
                highlight.fading = true
                if reduceMotion { highlight.window.orderOut(nil) }
                else { animateAlpha(highlight.window, to: 0, over: max(0.05, remaining - 0.02)) }
            }
            return highlight
        }
        schedule()
    }

    private func schedule() {
        guard !highlights.isEmpty else { timer?.invalidate(); timer = nil; return }
        let interval = highlights.contains { !$0.visible && !$0.fading } ? fastInterval : trackingInterval
        if let timer, timer.timeInterval == interval { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.update() }
    }

    private func animateAlpha(_ window: NSWindow, to alpha: CGFloat, over duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: alpha > 0 ? .easeOut : .easeIn)
            window.animator().alphaValue = alpha
        }
    }
}

/// One reusable capsule and a mouse-transparent highlight surface. Neither can
/// become key, and visual updates perform only read-only document queries.
final class CorrectionOverlayController: NSObject {
    private(set) var machine = CorrectionOverlayMachine()
    private var panel: CorrectionPanel?
    private var highlight: CorrectionPanel?
    private let correctedWordHighlights = CorrectedWordHighlights()
    private var stack: NSStackView?
    private var label: NSTextField?
    private var button: NSButton?
    private var divider: NSView?
    private var expiryTimer: Timer?
    private var trackingTimer: Timer?
    private var primaryAction: (() -> Void)?
    private var expiredAction: (() -> Void)?
    private var client: (any CorrectionClient)?
    private var anchor: CorrectionOverlayAnchor?
    private var presentedAt: TimeInterval = 0
    private var mismatchSince: TimeInterval?
    private var placedAtWord = false
    /// False for suggestions that only change capitalisation or apostrophes.
    private var showsSuggestionBox = false
    private var suggestionLookup: WordBoundsLookup?
    /// Presentation outcomes only; never document text.
    static let log = Logger(subsystem: "com.efekoy.inputmethod.Cappy", category: "overlay")

    deinit {
        expiryTimer?.invalidate()
        trackingTimer?.invalidate()
    }

    @discardableResult
    func show(_ presentation: SessionPresentation, client: any CorrectionClient,
              anchor: CorrectionOverlayAnchor? = nil,
              primary: @escaping () -> Void, secondary: @escaping () -> Void,
              expired: @escaping () -> Void = {}) -> Bool {
        expiryTimer?.invalidate(); trackingTimer?.invalidate()
        self.client = client; self.anchor = anchor
        presentedAt = ProcessInfo.processInfo.systemUptime
        suggestionLookup?.cancel(); suggestionLookup = nil
        mismatchSince = nil
        guard let geometry = geometry() else {
            placedAtWord = false
            Self.log.notice("Not shown: no word, caret, editor or window geometry")
            hide(); return false
        }
        placedAtWord = geometry.rangeRect != nil
        Self.log.notice("Shown at \(geometry.rangeRect != nil ? "word" : geometry.approximate ? "editor/window" : "caret", privacy: .public)")
        ensurePanel()
        let wasVisible = machine.state != .hidden && panel?.isVisible == true
        machine.present(presentation)
        let message: String, action: String
        switch presentation {
        case .corrected(let correction):
            message = "\(correction.original) → \(correction.replacement)"; action = "Undo"
        case .suggestion(let correction):
            message = "\(correction.original) → \(correction.replacement)"; action = "⇥"
        case .keep(let source): message = "Stop autocorrecting “\(source)”?"; action = "Yes"
        case .learned(let source): message = "✓ “\(source)” learned"; action = ""
        }
        primaryAction = primary; expiredAction = expired
        let text = NSMutableAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.labelColor
        ])
        switch presentation {
        case .corrected(let correction), .suggestion(let correction):
            let sourceLength = (correction.original as NSString).length
            text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                range: NSRange(location: 0, length: sourceLength))
            text.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                range: NSRange(location: sourceLength, length: 3))
            text.addAttribute(.font, value: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                range: NSRange(location: sourceLength + 3, length: (correction.replacement as NSString).length))
        case .learned:
            text.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: NSRange(location: 0, length: 1))
        default: break
        }
        label?.attributedStringValue = text
        divider?.isHidden = action.isEmpty
        button?.title = action; button?.isHidden = action.isEmpty
        button?.attributedTitle = NSAttributedString(string: action, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.systemBlue
        ])
        button?.toolTip = machine.state == .suggestion ? "Tab to accept · Escape to dismiss"
            : machine.state == .automaticCorrection ? "Undo correction (⌃⌥Z)" : action
        // Measure intrinsic content directly. A fittingSize query on the
        // already-constrained stack can retain the previous window's width.
        let actionWidth = action.isEmpty ? 0 : (button?.intrinsicContentSize.width ?? 0) + 13
        let width = min(320, max(72, ceil(text.size().width + actionWidth + 16)))
        let target = capsuleFrame(geometry, size: NSSize(width: width, height: 24))
        if wasVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                panel?.animator().setFrame(target, display: true)
            }
        } else { panel?.setFrame(target, display: true) }
        panel?.ignoresMouseEvents = action.isEmpty
        panel?.alphaValue = wasVisible ? 1 : 0
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
            panel?.animator().alphaValue = 1
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           let layer = panel?.contentView?.layer {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = wasVisible ? 0.985 : 0.96
            spring.toValue = 1
            spring.mass = 1; spring.stiffness = 320; spring.damping = 26
            spring.duration = spring.settlingDuration
            layer.add(spring, forKey: "capsuleSpring")
        }
        if case .suggestion(let correction) = presentation {
            showsSuggestionBox = !CorrectionOverlayAnchor.isCosmetic(correction.original, correction.replacement)
        }
        updateHighlight(geometry.rangeRect)
        let revision = machine.revision
        // Exact word bounds may arrive later from the host's accessibility
        // tree; the box and the capsule's move to the word wait for them.
        switch presentation {
        case .corrected(let correction):
            if let changed = anchor?.changedWords(from: correction.original) {
                correctedWordHighlights.show(client: client, anchor: changed) { [weak self] rect in
                    self?.moveToWord(rect, revision: revision)
                }
            }
        case .suggestion:
            if let anchor, geometry.rangeRect == nil {
                let lookup = WordBoundsLookup()
                suggestionLookup = lookup
                client.resolveTextRect(for: anchor.range, text: anchor.text, lookup: lookup) { [weak self] rect in
                    guard let self, self.machine.revision == revision else { return }
                    self.moveToWord(rect, revision: revision)
                    self.updateHighlight(rect)
                }
            }
        default: break
        }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: machine.duration, repeats: false) { [weak self] _ in
            guard let self, self.machine.revision == revision else { return }
            let callback = self.expiredAction
            self.hide(); callback?()
        }
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.followText() }
        return true
    }

    private struct Geometry {
        let rect: NSRect
        let rangeRect: NSRect?
        let screen: NSScreen
        /// `rect` is the editor or window, not text.
        let approximate: Bool
    }

    /// Word, then caret, then the editor or window, so feedback still
    /// appears in hosts that expose no text geometry at all.
    private func geometry() -> Geometry? {
        guard let client else { return nil }
        let rangeRect = anchor.flatMap { client.textRect(for: $0.range) }
        if let rect = rangeRect ?? client.caretRect(), CorrectionOverlayGeometry.isUsable(rect),
           let screen = CorrectionOverlayGeometry.screen(for: rect) {
            return Geometry(rect: rect, rangeRect: rangeRect, screen: screen, approximate: false)
        }
        guard let area = client.approximateAnchorRect(), area.width > 0, area.height > 0,
              let screen = CorrectionOverlayGeometry.screen(for: area) else { return nil }
        return Geometry(rect: area, rangeRect: nil, screen: screen, approximate: true)
    }

    private func capsuleFrame(_ geometry: Geometry, size: NSSize) -> NSRect {
        geometry.approximate
            ? CorrectionOverlayGeometry.approximateCapsuleFrame(area: geometry.rect, size: size, screen: geometry.screen.visibleFrame)
            : CorrectionOverlayGeometry.capsuleFrame(anchor: geometry.rect, size: size, screen: geometry.screen.visibleFrame)
    }

    /// Electron and Chromium hosts apply insertions and report the caret a
    /// little later than Cappy expects, so a mismatch must persist before the
    /// presentation ends. Keyboard navigation and clicks end it immediately
    /// through the session, and Undo and Tab revalidate the document themselves.
    static let mismatchTolerance: TimeInterval = 0.8

    private func followText() {
        guard let client else { return }
        // No host queries while keys arrive; see CorrectedWordHighlights.
        guard TypingActivity.isQuiet(for: CorrectedWordHighlights.typingQuiet) else { return }
        if let anchor {
            let selection = client.selectedRange()
            let matches = client.attributedSubstring(from: anchor.range)?.string == anchor.text
            if selection == NSRange(location: anchor.caret, length: 0), matches {
                mismatchSince = nil
            } else {
                let now = ProcessInfo.processInfo.systemUptime
                let since = mismatchSince ?? now
                mismatchSince = since
                if now - since >= Self.mismatchTolerance {
                    Self.log.notice("Ended: \(matches ? "caret moved" : "text changed", privacy: .public)")
                    endPresentation()
                }
                return
            }
        }
    }

    /// Move at most once, from the caret or editor to the word, then stay.
    private func moveToWord(_ rect: NSRect, revision: Int) {
        guard machine.revision == revision, machine.state != .hidden, !placedAtWord,
              let panel, let screen = CorrectionOverlayGeometry.screen(for: rect) else { return }
        placedAtWord = true
        let target = CorrectionOverlayGeometry.capsuleFrame(anchor: rect, size: panel.frame.size, screen: screen.visibleFrame)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { panel.setFrame(target, display: true); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(target, display: true)
        }
    }

    private func endPresentation() {
        let callback = expiredAction
        hide(); callback?()
    }

    func updateAnchor(_ anchor: CorrectionOverlayAnchor) {
        guard machine.state == .automaticCorrection else { hide(); return }
        self.anchor = anchor
    }

    func clearHighlights() { correctedWordHighlights.clear() }

    func hide() {
        suggestionLookup?.cancel(); suggestionLookup = nil
        expiryTimer?.invalidate(); expiryTimer = nil
        trackingTimer?.invalidate(); trackingTimer = nil
        machine.hide()
        primaryAction = nil; expiredAction = nil; client = nil; anchor = nil
        highlight?.orderOut(nil)
        let revision = machine.revision
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            panel?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.machine.revision == revision else { return }
            self.panel?.orderOut(nil)
        })
    }

    private func makePanel() -> CorrectionPanel {
        let window = CorrectionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .popUpMenu; window.isFloatingPanel = true; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isOpaque = false; window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        return window
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let window = makePanel(); window.hasShadow = true
        let bounds = NSRect(x: 0, y: 0, width: 120, height: 24)
        let container = NSView(frame: bounds)
        container.wantsLayer = true
        let content = NSView(frame: bounds)
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .clear; glass.cornerRadius = 10; glass.contentView = content
            background = glass
        } else {
            let effect = NSVisualEffectView(frame: bounds)
            effect.material = .popover; effect.state = .active; effect.blendingMode = .behindWindow
            effect.wantsLayer = true; effect.layer?.cornerRadius = 10; effect.layer?.masksToBounds = true
            effect.addSubview(content); background = effect
        }
        content.autoresizingMask = [.width, .height]
        background.autoresizingMask = [.width, .height]; container.addSubview(background)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 10.5); label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let button = NSButton(title: "", target: self, action: #selector(performPrimary))
        button.isBordered = false; button.refusesFirstResponder = true
        button.focusRingType = .none
        button.font = .systemFont(ofSize: 10.5, weight: .medium)
        let divider = NSView(); divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 10)
        ])
        let stack = NSStackView(views: [label, divider, button]); stack.spacing = 6
        content.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        window.contentView = container
        self.panel = window; self.stack = stack; self.label = label; self.button = button; self.divider = divider
    }

    private func updateHighlight(_ rect: NSRect?) {
        guard machine.state == .suggestion, showsSuggestionBox, let rect,
              rect.width > 1, CorrectionOverlayGeometry.isUsable(rect) else { highlight?.orderOut(nil); return }
        if highlight == nil {
            let window = makePanel(); window.ignoresMouseEvents = true; window.hasShadow = false
            window.contentView = CorrectionHighlightStyle.makeView(); highlight = window
        }
        highlight?.setFrame(CorrectionHighlightStyle.frame(around: rect), display: true)
        highlight?.orderFrontRegardless()
    }

    @objc private func performPrimary() {
        // Keep the existing window alive so Undo → Keep → Learned can morph.
        primaryAction?()
    }
}

final class PersonalisationSettingsController {
    static let shared = PersonalisationSettingsController()
    private var window: NSWindow?
    func show() {
        if let window {
            ProtectedWords.shared.reload()
            window.contentView = NSHostingView(rootView: PersonalisationSettingsView())
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Cappy Personalisation"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PersonalisationSettingsView())
        window.center(); window.makeKeyAndOrderFront(nil); self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct PersonalisationSettingsView: View {
    @State private var revision = 0
    @State private var newWord = ""
    @State private var error = ""
    private let protected = ProtectedWords.shared
    private let store = PersonalizationStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cappy Personalisation").font(.title2.bold())
            Text("Learning stays on this Mac. Remove a preference to restore Cappy’s default behaviour.").font(.callout).foregroundColor(.secondary)
            HStack {
                TextField("Word to always keep", text: $newWord).onSubmit(addWord)
                Button("Add", action: addWord)
            }
            if !error.isEmpty { Text(error).foregroundColor(.red).font(.caption) }
            TabView {
                List {
                    ForEach(protected.words.sorted(), id: \.self) { word in
                        HStack {
                            Text(word); Spacer()
                            Button("Remove") {
                                if protected.remove(word) { store.removeVocabulary(word); store.flush(); revision += 1 }
                                else { error = "Could not save protected words." }
                            }
                        }
                    }
                }.tabItem { Text("Protected Words") }
                List {
                    ForEach(store.records.keys.sorted(), id: \.self) { key in
                        if let record = store.records[key] {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(record.source) → \(record.replacement)")
                                    Text("Accepted \(record.automaticAccepted + record.suggestionsAccepted) · Undone \(record.automaticUndone) · Dismissed \(record.suggestionsRejected) · Ignored \(record.suggestionsIgnored)\(record.explicitlySuppressed == true ? " · Suppressed" : record.context.isEmpty ? "" : " · Context-specific")")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Remove") { store.removeRecord(key); store.flush(); revision += 1 }
                            }
                        }
                    }
                }.tabItem { Text("Learned Corrections") }
                List {
                    ForEach(store.vocabulary.keys.sorted(), id: \.self) { word in
                        HStack {
                            Text(word)
                            Text(store.vocabularyState(word, protectedWords: protected).rawValue).foregroundColor(.secondary)
                            Spacer()
                            Button("Always Keep") { newWord = word; addWord() }
                            Button("Remove") { store.removeVocabulary(word); store.flush(); revision += 1 }
                        }
                    }
                }.tabItem { Text("Observed Vocabulary") }
            }
            HStack {
                Text("Blue highlights in Chrome, Discord and other web editors").font(.caption)
                Spacer()
                Button("Enable Accessibility…") { AccessibleWordBounds.requestAccess() }
            }
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                Text(AXIsProcessTrusted() ? "Accessibility enabled" : "Accessibility required: enable Cappy in System Settings → Privacy & Security → Accessibility")
                    .font(.caption).foregroundColor(.secondary)
            }
            Text("Automatic ≥ 0.98 · Suggestion ≥ 0.75 · Weaker candidates stay untouched").font(.caption).foregroundColor(.secondary)
        }.padding(20).id(revision)
    }
    private func addWord() {
        if protected.protect(newWord) { newWord = ""; error = ""; revision += 1 }
        else { error = "Enter one word (up to 32 letters or apostrophes). Check that the file is writable." }
    }
}
