import AppKit
import ApplicationServices
import Carbon
import os

/// Accessibility is an optional, permission-gated bridge for web-based editors.
/// It only reads the foreground editable element; replacements still go via IMK.
enum CrossAppAccessibility {
    static let maximumTextLength = 16_384
    private static var preparedPID: pid_t?
    /// Bound every Accessibility round trip, including elements created without
    /// their own timeout. The system default is six seconds per call, which
    /// would stall Cappy's main thread and every key and click it handles.
    private static let boundedMessaging: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.1)
    }()

    static func prepare(_ app: NSRunningApplication) {
        _ = boundedMessaging
        guard AXIsProcessTrusted(), preparedPID != app.processIdentifier else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.03)
        // Electron's documented opt-in exposes its renderer accessibility tree.
        // Other applications simply report attributeUnsupported.
        _ = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        preparedPID = app.processIdentifier
    }

    static func value(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        _ = boundedMessaging
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    static func parameter(_ name: String, _ argument: CFTypeRef, of element: AXUIElement) -> CFTypeRef? {
        _ = boundedMessaging
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &result) == .success else { return nil }
        return result
    }

    static func range(_ value: CFTypeRef?) -> NSRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0,
              range.location != NSNotFound, range.length >= 0, range.location <= Int.max - range.length else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    static func parameter(for range: NSRange) -> AXValue? {
        guard range.location >= 0, range.location != NSNotFound, range.length >= 0,
              range.location <= Int.max - range.length else { return nil }
        var range = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &range)
    }

    static func focusedEditor(in app: NSRunningApplication) -> AXUIElement? {
        focusedEditor(pid: app.processIdentifier)
    }

    /// Safe off the main thread: Accessibility calls only, no AppKit.
    static func focusedEditor(pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.08)
        // Electron apps can leave the application's focus attribute empty while
        // the system-wide element still reports the focused web editor.
        guard let focused = element(value(kAXFocusedUIElementAttribute, of: application))
                ?? element(value(kAXFocusedUIElementAttribute, of: AXUIElementCreateSystemWide()), pid: pid)
        else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.08)
        // Web editors may focus a child of the editable region.
        let editor = isEditor(focused) ? focused
            : element(value("AXEditableAncestor", of: focused), pid: pid).flatMap { isEditor($0) ? $0 : nil }
        guard let editor, value(kAXSubroleAttribute, of: editor) as? String != kAXSecureTextFieldSubrole else { return nil }
        AXUIElementSetMessagingTimeout(editor, 0.08)
        return editor
    }

    private static func element(_ raw: CFTypeRef?, pid: pid_t? = nil) -> AXUIElement? {
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        var owner: pid_t = 0
        if let pid, AXUIElementGetPid(element, &owner) != .success || owner != pid { return nil }
        return element
    }

    private static func isEditor(_ element: AXUIElement) -> Bool {
        guard let role = value(kAXRoleAttribute, of: element) as? String else { return false }
        return [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role)
    }

    static func bounds(for range: NSRange, editor: AXUIElement) -> NSRect? {
        guard let argument = parameter(for: range),
              let value = parameter(kAXBoundsForRangeParameterizedAttribute, argument, of: editor),
              CFGetTypeID(value) == AXValueGetTypeID(), let primary = NSScreen.screens.first else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &bounds) else { return nil }
        return AccessibleWordBounds.screenRect(bounds, primaryScreenTop: primary.frame.maxY)
    }

    /// The editor's selection as text markers. Chromium, Electron and WebKit
    /// expose this even when index-based geometry is empty, and it does not
    /// depend on IMK and Accessibility agreeing on document offsets.
    static func selectionMarkers(editor: AXUIElement) -> AXTextMarkerRange? {
        guard let raw = value("AXSelectedTextMarkerRange", of: editor),
              CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() else { return nil }
        return (raw as! AXTextMarkerRange)
    }

    /// Zero-width rectangles are allowed so a collapsed range can supply a caret.
    /// Chrome answers with the whole editor's frame when it has no text
    /// layout for the range; that is not text geometry and is rejected.
    private static func bounds(of markers: AXTextMarkerRange, editor: AXUIElement) -> NSRect? {
        guard let value = parameter("AXBoundsForTextMarkerRange", markers, of: editor),
              CFGetTypeID(value) == AXValueGetTypeID(), let primary = NSScreen.screens.first else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &bounds), bounds.origin != .zero, bounds.height > 1 else { return nil }
        let rect = NSRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
        guard CorrectionOverlayGeometry.isUsable(rect) else { return nil }
        if let frame = frame(of: editor), CorrectionOverlayGeometry.isWholeElement(rect, frame: frame) { return nil }
        return rect
    }

    /// Markers at 0, 1, 2… characters before the caret, stopping at the start.
    static func markersBeforeCaret(_ count: Int, editor: AXUIElement) -> [AXTextMarker] {
        guard let selection = selectionMarkers(editor: editor) else { return [] }
        var markers = [AXTextMarkerRangeCopyEndMarker(selection)]
        while markers.count <= count {
            guard let raw = parameter("AXPreviousTextMarkerForTextMarker", markers[markers.count - 1], of: editor),
                  CFGetTypeID(raw) == AXTextMarkerGetTypeID() else { break }
            markers.append(raw as! AXTextMarker)
        }
        return markers
    }

    /// Bounds of text ending one of `distances` characters before the caret,
    /// walking markers back from the editor's own selection. When `expected`
    /// is given, the range must read back as exactly that text.
    static func markerBounds(backFromCaret distances: [Int], length: Int, expected: String?, editor: AXUIElement) -> NSRect? {
        let distances = distances.filter { $0 >= 0 && $0 <= 96 }
        guard length > 0, length <= 64, let farthest = distances.max() else { return nil }
        let markers = markersBeforeCaret(farthest + length, editor: editor)
        for distance in distances where distance + length < markers.count {
            let range = AXTextMarkerRangeCreate(kCFAllocatorDefault, markers[distance + length], markers[distance])
            if let expected, parameter("AXStringForTextMarkerRange", range, of: editor) as? String != expected { continue }
            if let rect = bounds(of: range, editor: editor), rect.width > 1 { return rect }
        }
        return nil
    }

    /// The insertion point, from text markers or the character before it.
    static func caretMarkerBounds(editor: AXUIElement) -> NSRect? {
        if let selection = selectionMarkers(editor: editor) {
            let end = AXTextMarkerRangeCopyEndMarker(selection)
            if let rect = bounds(of: AXTextMarkerRangeCreate(kCFAllocatorDefault, end, end), editor: editor) {
                return NSRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
            }
            if let rect = markerBounds(backFromCaret: [0], length: 1, expected: nil, editor: editor) {
                return NSRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
            }
        }
        guard let selection = range(value(kAXSelectedTextRangeAttribute, of: editor)), NSMaxRange(selection) > 0,
              let rect = bounds(for: NSRange(location: NSMaxRange(selection) - 1, length: 1), editor: editor) else { return nil }
        return NSRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
    }

    /// The element's own frame. Chromium reports element frames even when it
    /// omits text geometry, so this bounds the select-word fallback to the editor.
    static func frame(of element: AXUIElement) -> NSRect? {
        guard let rawPosition = value(kAXPositionAttribute, of: element), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              let rawSize = value(kAXSizeAttribute, of: element), CFGetTypeID(rawSize) == AXValueGetTypeID(),
              let primary = NSScreen.screens.first else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size), size.width > 1, size.height > 1 else { return nil }
        return NSRect(x: position.x, y: primary.frame.maxY - position.y - size.height, width: size.width, height: size.height)
    }

    /// Diagnostics deliberately report capabilities and counts, never editor text.
    static func diagnosticStatus(bundleIdentifier: String? = nil) -> String {
        var lines = ["Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")"]
        let target = bundleIdentifier.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        guard let app = target ?? NSWorkspace.shared.frontmostApplication else { return lines.joined(separator: "\n") }
        lines.append("App: \(app.bundleIdentifier ?? "unknown")")
        prepare(app)
        // Electron builds its accessibility tree asynchronously after opting in.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        let application = AXUIElementCreateApplication(app.processIdentifier)
        if let raw = value(kAXFocusedUIElementAttribute, of: application), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let focused = raw as! AXUIElement
            lines.append("Focused element role: \(value(kAXRoleAttribute, of: focused) as? String ?? "none"), subrole: \(value(kAXSubroleAttribute, of: focused) as? String ?? "none")")
        } else {
            lines.append("Focused element: none")
        }
        guard let editor = focusedEditor(in: app) else {
            lines.append("Focused editable element: unavailable")
            return lines.joined(separator: "\n")
        }
        lines.append("Focused editable element: available")
        let selection = range(value(kAXSelectedTextRangeAttribute, of: editor))
        lines.append("Selection: \(selection.map { "\($0.location),\($0.length)" } ?? "unavailable")")
        var names: CFArray?
        if AXUIElementCopyParameterizedAttributeNames(editor, &names) == .success {
            lines.append("Text APIs: \((names as? [String] ?? []).joined(separator: ", "))")
        }
        lines.append("Editor frame: \(frame(of: editor).map { "\($0)" } ?? "unavailable")")
        lines.append("Caret marker bounds: \(caretMarkerBounds(editor: editor).map { "\($0)" } ?? "unavailable")")
        lines.append("Previous character via markers: \(markerBounds(backFromCaret: [0], length: 1, expected: nil, editor: editor).map { "\($0)" } ?? "unavailable")")
        if let word = ProcessInfo.processInfo.environment["CAPPY_DIAGNOSE_WORD"] {
            let trailing = Int(ProcessInfo.processInfo.environment["CAPPY_DIAGNOSE_TRAILING"] ?? "") ?? 0
            var result: CGRect?, attempts = 0
            while result == nil, attempts < 60 {
                attempts += 1
                result = AccessibleWordLocator.attemptOnce(word: word, trailing: trailing, pid: app.processIdentifier)
                if result == nil { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
            }
            lines.append("Exact word bounds after \(attempts) attempts: \(result.map { "\($0)" } ?? "unavailable")")
        }
        lines.append("Window frame: \(FocusedWindowFrame.frame(pid: app.processIdentifier).map { "\($0)" } ?? "unavailable")")
        if let text = value(kAXValueAttribute, of: editor) as? String {
            lines.append("Editor UTF-16 length: \((text as NSString).length)")
            if let selection, selection.location > 0 {
                let previous = NSRange(location: selection.location - 1, length: 1)
                var raw = CGRect.null
                if let argument = parameter(for: previous),
                   let value = parameter(kAXBoundsForRangeParameterizedAttribute, argument, of: editor),
                   CFGetTypeID(value) == AXValueGetTypeID() { AXValueGetValue(value as! AXValue, .cgRect, &raw) }
                lines.append("Previous character BoundsForRange: \(raw)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// The app's frontmost window from the window server. This needs no
/// permission, so it anchors feedback in apps that expose no text geometry.
enum FocusedWindowFrame {
    static func frame(pid: pid_t) -> NSRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let top = NSScreen.screens.first?.frame.maxY else { return nil }
        // Front-to-back order: the first ordinary window is the active one.
        for window in windows where window[kCGWindowOwnerPID as String] as? pid_t == pid
            && window[kCGWindowLayer as String] as? Int == 0 {
            guard let raw = window[kCGWindowBounds as String], let bounds = CGRect(dictionaryRepresentation: raw as! CFDictionary),
                  bounds.width > 80, bounds.height > 40 else { continue }
            return NSRect(x: bounds.minX, y: top - bounds.maxY, width: bounds.width, height: bounds.height)
        }
        return nil
    }
}

/// The latest key event, readable from background work. Lookups into the
/// host wait for a pause so they never compete with typing on its main thread.
enum TypingActivity {
    private static let lock = NSLock()
    private static var last: TimeInterval = -.infinity

    static func noteKey(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock { last = time }
    }

    static var lastKey: TimeInterval { lock.withLock { last } }

    static func isQuiet(for interval: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        now - lastKey >= interval
    }
}

/// Cancels a pending word lookup. Cancelled from the main thread, read by the lookup.
final class WordBoundsLookup: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// Finds text near the caret by content, not by offset. IMK and the host's
/// accessibility tree disagree about offsets while the host catches up.
enum AccessibleWordMatch {
    /// Distances from `caretOffset` back to the end of each whole-word
    /// occurrence of `word` in `window`, nearest to `expected` first, within
    /// `tolerance` of it.
    static func distances(in window: String, caretOffset: Int, word: String, expected: Int, tolerance: Int = 6) -> [Int] {
        let text = window as NSString, length = (word as NSString).length
        guard length > 0, caretOffset >= 0, caretOffset <= text.length else { return [] }
        func isWordPart(_ index: Int) -> Bool {
            guard index >= 0, index < text.length, let scalar = UnicodeScalar(text.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == "’"
        }
        var found: [Int] = []
        var search = NSRange(location: 0, length: text.length)
        while true {
            let match = text.range(of: word, options: [], range: search)
            guard match.location != NSNotFound else { break }
            let distance = caretOffset - NSMaxRange(match)
            if distance >= 0, abs(distance - expected) <= tolerance,
               !isWordPart(match.location - 1), !isWordPart(NSMaxRange(match)) { found.append(distance) }
            let next = match.location + 1
            guard next < text.length else { break }
            search = NSRange(location: next, length: text.length - next)
        }
        return found.sorted { abs($0 - expected) < abs($1 - expected) }
    }

    /// A rectangle a host reported for text: non-empty, line-sized, and not
    /// just the editor's own frame (Chrome's answer when it has no layout).
    static func isTextBounds(_ rect: CGRect, editorFrame: CGRect?) -> Bool {
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 1, rect.width < 2000, rect.height >= 4, rect.height < 200 else { return false }
        if let frame = editorFrame, CorrectionOverlayGeometry.isWholeElement(rect, frame: frame) { return false }
        return true
    }
}

/// Exact word bounds from Accessibility, fetched on a background queue and
/// retried until the host's accessibility tree has caught up with the text.
/// Never estimated: no answer means no box.
enum AccessibleWordLocator {
    static let attemptInterval: TimeInterval = 0.05
    static let typingQuiet: TimeInterval = 0.08
    static let timeLimit: TimeInterval = 2
    private static let queue = DispatchQueue(label: "com.efekoy.inputmethod.Cappy.wordbounds", qos: .userInitiated)
    /// Outcomes and timings only; never document text.
    private static let log = Logger(subsystem: "com.efekoy.inputmethod.Cappy", category: "highlight")

    /// Finds `word`, which ends `trailing` UTF-16 units before the caret, in
    /// the focused editor of `pid`. `completion` runs on the main thread.
    static func locate(word: String, trailing: Int, pid: pid_t, lookup: WordBoundsLookup,
                       completion: @escaping (NSRect) -> Void) {
        guard AXIsProcessTrusted(), !word.isEmpty, trailing >= 0, let top = NSScreen.screens.first?.frame.maxY else { return }
        let started = ProcessInfo.processInfo.systemUptime
        func attempt(_ count: Int, lastMiss: String) {
            guard !lookup.isCancelled else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - started < timeLimit else {
                log.notice("Word bounds: gave up after \(count, privacy: .public) attempts (\(lastMiss, privacy: .public))")
                return
            }
            guard TypingActivity.isQuiet(for: typingQuiet, now: now) else {
                queue.asyncAfter(deadline: .now() + 0.03) { attempt(count, lastMiss: lastMiss) }
                return
            }
            // Chromium lays out text for accessibility lazily, when a client
            // asks for a text element's children. Ask once early, and again
            // later in case the editor's content was replaced meanwhile.
            switch find(word: word, trailing: trailing, pid: pid, loadLayout: count == 1 || count == 12) {
            case .success(let raw):
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                log.notice("Word bounds: exact after \(count + 1, privacy: .public) attempts, \(elapsed, privacy: .public) ms")
                let rect = NSRect(x: raw.minX, y: top - raw.maxY, width: raw.width, height: raw.height)
                DispatchQueue.main.async { if !lookup.isCancelled { completion(rect) } }
            case .failure(let miss):
                queue.asyncAfter(deadline: .now() + attemptInterval) { attempt(count + 1, lastMiss: miss.reason) }
            }
        }
        queue.async { attempt(0, lastMiss: "none") }
    }

    /// One synchronous attempt, for diagnostics.
    static func attemptOnce(word: String, trailing: Int, pid: pid_t) -> CGRect? {
        try? find(word: word, trailing: trailing, pid: pid, loadLayout: true).get()
    }

    private struct Miss: Error { var reason: String }

    /// One attempt, in Accessibility's top-left screen coordinates.
    private static func find(word: String, trailing: Int, pid: pid_t, loadLayout: Bool) -> Result<CGRect, Miss> {
        guard let editor = CrossAppAccessibility.focusedEditor(pid: pid) else { return .failure(Miss(reason: "no focused editor")) }
        if loadLayout { requestTextLayout(in: editor) }
        let frame = rawFrame(of: editor)
        var miss = Miss(reason: "no text near caret")
        if let rect = markerBounds(word: word, trailing: trailing, editor: editor, frame: frame, miss: &miss) { return .success(rect) }
        if let rect = indexBounds(word: word, trailing: trailing, editor: editor, frame: frame, miss: &miss) { return .success(rect) }
        return .failure(miss)
    }

    /// Reads the children of the editor's subtree, bounded, which makes
    /// Chromium build the inline text boxes that word bounds come from.
    private static func requestTextLayout(in editor: AXUIElement) {
        var queue = [editor], visited = 0
        while !queue.isEmpty, visited < 300 {
            let element = queue.removeFirst()
            visited += 1
            guard let children = CrossAppAccessibility.value(kAXChildrenAttribute, of: element) as? [AXUIElement] else { continue }
            queue.append(contentsOf: children.prefix(50))
        }
    }

    /// Chromium, Electron and WebKit: walk text markers back from the
    /// editor's own caret and search that text for the word.
    private static func markerBounds(word: String, trailing: Int, editor: AXUIElement, frame: CGRect?, miss: inout Miss) -> CGRect? {
        let length = (word as NSString).length
        let markers = CrossAppAccessibility.markersBeforeCaret(min(trailing + length + 8, 160), editor: editor)
        guard markers.count > length,
              let window = CrossAppAccessibility.parameter("AXStringForTextMarkerRange",
                  AXTextMarkerRangeCreate(kCFAllocatorDefault, markers[markers.count - 1], markers[0]), of: editor) as? String
        else { return nil }
        let distances = AccessibleWordMatch.distances(in: window, caretOffset: (window as NSString).length, word: word, expected: trailing)
        miss = Miss(reason: distances.isEmpty ? "word not in text near caret" : "word found, no text bounds")
        for distance in distances where distance + length < markers.count {
            let range = AXTextMarkerRangeCreate(kCFAllocatorDefault, markers[distance + length], markers[distance])
            guard CrossAppAccessibility.parameter("AXStringForTextMarkerRange", range, of: editor) as? String == word,
                  let rect = rect(CrossAppAccessibility.parameter("AXBoundsForTextMarkerRange", range, of: editor)),
                  AccessibleWordMatch.isTextBounds(rect, editorFrame: frame) else { continue }
            return rect
        }
        return nil
    }

    /// Native editors: search the value around the selection and ask for
    /// bounds of that exact range.
    private static func indexBounds(word: String, trailing: Int, editor: AXUIElement, frame: CGRect?, miss: inout Miss) -> CGRect? {
        guard let value = CrossAppAccessibility.value(kAXValueAttribute, of: editor) as? String,
              (value as NSString).length <= CrossAppAccessibility.maximumTextLength,
              let selection = CrossAppAccessibility.range(CrossAppAccessibility.value(kAXSelectedTextRangeAttribute, of: editor)) else { return nil }
        let text = value as NSString, length = (word as NSString).length
        let caret = NSMaxRange(selection)
        guard caret <= text.length else { return nil }
        let start = max(0, caret - trailing - length - 8), end = min(text.length, caret + 8)
        let window = text.substring(with: NSRange(location: start, length: end - start))
        let distances = AccessibleWordMatch.distances(in: window, caretOffset: caret - start, word: word, expected: trailing)
        if !distances.isEmpty { miss = Miss(reason: "word found, no text bounds") }
        for distance in distances {
            let range = NSRange(location: caret - distance - length, length: length)
            guard let argument = CrossAppAccessibility.parameter(for: range),
                  let rect = rect(CrossAppAccessibility.parameter(kAXBoundsForRangeParameterizedAttribute, argument, of: editor)),
                  AccessibleWordMatch.isTextBounds(rect, editorFrame: frame) else { continue }
            return rect
        }
        return nil
    }

    private static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }

    private static func rawFrame(of element: AXUIElement) -> CGRect? {
        guard let rawPosition = CrossAppAccessibility.value(kAXPositionAttribute, of: element), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              let rawSize = CrossAppAccessibility.value(kAXSizeAttribute, of: element), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
