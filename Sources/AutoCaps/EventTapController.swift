import AppKit
import CoreGraphics

private let autoCapsEventTag: Int64 = 0x4155_544F_4341_5053

final class EventTapController {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var engine = TextEngine()
    private let settings: Settings
    private var mayUseDiscordFocusFallback = false
    /// Privacy-preserving Discord workaround: an integer count only, never text.
    private var discordEstimatedLength: Int?
    private var discordSelectionAll = false
    private var pendingUndo: (correction: RecentCorrection, pid: pid_t)?
    private var pendingSpellCheck: UUID?

    init(settings: Settings = .shared) { self.settings = settings }
    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil, Permissions.allGranted else { return eventTap != nil }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue().receive(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        pendingSpellCheck = nil
        clearUndo()
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        runLoopSource = nil
        eventTap = nil
        engine.invalidateContext()
        mayUseDiscordFocusFallback = false
        discordEstimatedLength = nil
        discordSelectionAll = false
    }

    func invalidateContext() {
        pendingSpellCheck = nil
        clearUndo()
        engine.invalidateContext()
        mayUseDiscordFocusFallback = false
        discordEstimatedLength = nil
        discordSelectionAll = false
    }

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            pendingSpellCheck = nil
            clearUndo()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            engine.invalidateContext()
            mayUseDiscordFocusFallback = false
            discordEstimatedLength = nil
            discordSelectionAll = false
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown || type == .scrollWheel {
            pendingSpellCheck = nil
            clearUndo()
            engine.invalidateContext()
            // A different DM may have an unfinished draft. Mouse focus alone
            // never proves that the insertion point is at the start.
            mayUseDiscordFocusFallback = false
            discordEstimatedLength = nil
            discordSelectionAll = false
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown,
              event.getIntegerValueField(.eventSourceUserData) != autoCapsEventTag,
              settings.enabled else { return Unmanaged.passUnretained(event) }

        if isWindowsAppFrontmost {
            invalidateContext()
            return Unmanaged.passUnretained(event)
        }

        pendingSpellCheck = nil

        let flags = event.flags
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == 51,
           flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty,
           restoreCorrection(removingSpace: true) {
            return nil
        }
        // An undo applies only to the very next typing action. Modifier-only
        // events need not cancel it; shortcuts and all actual keys do.
        clearUndo()
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty {
            engine.invalidateContext()
            mayUseDiscordFocusFallback = false
            handleDiscordShortcut(keyCode: keyCode, flags: flags)
            return Unmanaged.passUnretained(event)
        }
        if Self.invalidatesContext(keyCode) {
            if keyCode == 51 || keyCode == 117 {
                engine.handleBackspace()
            } else {
                engine.invalidateContext()
            }
            handleDiscordNavigation(keyCode: keyCode)
            return Unmanaged.passUnretained(event)
        }

        if isDiscordFrontmost && discordSelectionAll {
            // Typing replaces the selected composer contents.
            discordEstimatedLength = 0
            discordSelectionAll = false
            engine.applyContext("")
            mayUseDiscordFocusFallback = false
        }

        let needsPrefix = engine.needsExternalContext
        switch AccessibilityContext.inspectFocusedElement(readPrefix: needsPrefix) {
        case .secure:
            engine.invalidateContext()
            mayUseDiscordFocusFallback = false
            return Unmanaged.passUnretained(event)
        case .unavailable:
            if needsPrefix { applyUnavailableContext() }
        case .editable(let prefix):
            if needsPrefix {
                if let prefix {
                    engine.applyContext(prefix)
                    mayUseDiscordFocusFallback = false
                    if isDiscordFrontmost && prefix.isEmpty { discordEstimatedLength = 0 }
                } else {
                    applyUnavailableContext()
                }
            }
        }

        guard let text = event.unicodeText, text.count == 1, let character = text.first else {
            engine.invalidateContext()
            mayUseDiscordFocusFallback = false
            return Unmanaged.passUnretained(event)
        }
        let features = settings.features
        let typoRequest = character == " " ? engine.typoRequestAtBoundary(features: features) : nil
        let decision = engine.handle(character: character, features: features) { word in
            SpellCorrector.shared.cachedSuggestion(for: word)
        }
        updateDiscordEstimate(character: character, decision: decision, flags: flags)
        switch decision {
        case .pass:
            if let typoRequest { requestDelayedCorrection(typoRequest, suffix: " ") }
            return Unmanaged.passUnretained(event)
        case .replaceCurrentEvent(let replacement):
            event.setUnicodeText(replacement)
            return Unmanaged.passUnretained(event)
        case .edit(let edit):
            let correction = engine.recentCorrection
            post(edit: edit)
            if let correction, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                pendingUndo = (correction, pid)
            }
            return nil
        }
    }

    private func requestDelayedCorrection(_ request: TypoRequest, suffix: String) {
        let id = UUID()
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        pendingSpellCheck = id
        SpellCorrector.shared.requestSuggestion(for: request.word) { [weak self] suggestion in
            guard let self, self.pendingSpellCheck == id,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self.pendingSpellCheck = nil
            guard let suggestion,
                  let result = self.engine.applyDelayedTypoSuggestion(
                    suggestion, request: request, suffix: suffix, features: self.settings.features
                  ) else { return }
            self.post(edit: result.edit)
            if let pid { self.pendingUndo = (result.correction, pid) }
            if let length = self.discordEstimatedLength {
                self.discordEstimatedLength = max(0, length - result.edit.backspaces) + result.edit.insertion.count
            }
        }
    }

    @discardableResult
    private func restoreCorrection(removingSpace: Bool) -> Bool {
        guard let pending = pendingUndo else { return false }
        guard settings.enabled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pending.pid else {
            clearUndo()
            return false
        }
        let edit = pending.correction.undoEdit(removingSpace: removingSpace)
        clearUndo()
        post(edit: edit)
        engine.restore(pending.correction, removingSpace: removingSpace)
        if let length = discordEstimatedLength {
            discordEstimatedLength = max(0, length - edit.backspaces) + edit.insertion.count
        }
        mayUseDiscordFocusFallback = false
        return true
    }

    private func clearUndo() {
        pendingUndo = nil
        engine.discardRecentCorrection()
    }

    private func applyUnavailableContext() {
        // Discord's message composer currently exposes neither AXSelectedTextRange
        // nor Chromium's text-marker attributes while it is empty. Limit the
        // workaround to the first key after a mouse focus change in Discord.
        let assumeEmpty = isDiscordFrontmost && mayUseDiscordFocusFallback && discordEstimatedLength == 0
        engine.applyContext(assumeEmpty ? "" : nil)
        if assumeEmpty { discordEstimatedLength = 0 }
        mayUseDiscordFocusFallback = false
    }

    private var isDiscordFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.hnc.Discord"
    }

    private var isWindowsAppFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.microsoft.rdc.macos"
    }

    private func handleDiscordShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard isDiscordFrontmost else {
            discordEstimatedLength = nil
            discordSelectionAll = false
            return
        }
        guard flags.contains(.maskCommand) else {
            discordEstimatedLength = nil
            discordSelectionAll = false
            return
        }

        switch keyCode {
        case 0: // Command+A
            discordSelectionAll = discordEstimatedLength != nil
        case 51, 117: // Command+Delete may remove only one line.
            if discordSelectionAll {
                discordEstimatedLength = 0
                mayUseDiscordFocusFallback = true
            } else {
                discordEstimatedLength = nil
            }
            discordSelectionAll = false
        case 7 where discordSelectionAll: // Command+X after Command+A
            discordEstimatedLength = 0
            discordSelectionAll = false
            mayUseDiscordFocusFallback = true
        case 9: // Paste makes the count unknowable without reading clipboard data.
            discordEstimatedLength = nil
            discordSelectionAll = false
        default:
            break
        }
    }

    private func handleDiscordNavigation(keyCode: CGKeyCode) {
        guard isDiscordFrontmost else {
            mayUseDiscordFocusFallback = false
            discordEstimatedLength = nil
            discordSelectionAll = false
            return
        }

        if keyCode == 51 || keyCode == 117 {
            if discordSelectionAll {
                discordEstimatedLength = 0
                discordSelectionAll = false
            } else if let length = discordEstimatedLength {
                discordEstimatedLength = max(0, length - 1)
            }
            mayUseDiscordFocusFallback = discordEstimatedLength == 0
        } else {
            mayUseDiscordFocusFallback = false
            discordSelectionAll = false
        }
    }

    private func updateDiscordEstimate(character: Character, decision: TextDecision, flags: CGEventFlags) {
        guard isDiscordFrontmost else { return }

        // Plain Return sends and clears a Discord message. Shift+Return inserts a newline.
        if (character == "\n" || character == "\r") && !flags.contains(.maskShift) {
            discordEstimatedLength = 0
            discordSelectionAll = false
            return
        }
        guard let length = discordEstimatedLength else { return }
        switch decision {
        case .pass:
            discordEstimatedLength = length + 1
        case .replaceCurrentEvent(let replacement):
            discordEstimatedLength = length + replacement.count
        case .edit(let edit):
            discordEstimatedLength = max(0, length - edit.backspaces) + edit.insertion.count
        }
        discordSelectionAll = false
    }

    private func post(edit: TextEdit) {
        for _ in 0..<edit.backspaces {
            postKey(keyCode: 51, down: true)
            postKey(keyCode: 51, down: false)
        }
        // Chromium/Electron editors commonly truncate a multi-character Unicode
        // payload on one key event, so replacements are emitted character by character.
        for character in edit.insertion { postText(String(character)) }
    }

    private func postText(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        down.setIntegerValueField(.eventSourceUserData, value: autoCapsEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: autoCapsEventTag)
        down.setUnicodeText(text)
        up.setUnicodeText(text)
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func postKey(keyCode: CGKeyCode, down: Bool) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: autoCapsEventTag)
        event.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static func invalidatesContext(_ code: CGKeyCode) -> Bool {
        [51, 117, 48, 53, 115, 119, 116, 121, 123, 124, 125, 126].contains(code)
    }

}

private extension CGEvent {
    var unicodeText: String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return length > 0 ? String(utf16CodeUnits: buffer, count: length) : nil
    }
    func setUnicodeText(_ text: String) {
        let units = Array(text.utf16)
        keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
    }
}
