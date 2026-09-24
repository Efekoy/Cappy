import ApplicationServices
import Foundation

enum FocusInspection { case unavailable, secure, editable(prefix: String?) }

enum AccessibilityContext {
    private static let maximumPrefixLength = 64
    /// Reads only a tiny range before the cursor, never the complete field value.
    static func inspectFocusedElement(readPrefix: Bool) -> FocusInspection {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unavailable }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        if isSecure(element) { return .secure }
        return .editable(prefix: readPrefix ? prefixBeforeCursor(in: element) : nil)
    }
    private static func isSecure(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success
            && (value as? String) == kAXSecureTextFieldSubrole as String
    }
    static func prefixBeforeCursor(in element: AXUIElement) -> String? {
        // Chromium/Electron text controls often expose their character count but
        // not AXStringForRange. A zero count identifies a genuinely empty editor
        // without asking Accessibility for the field's full value.
        if numberOfCharacters(in: element) == 0 { return "" }

        if let prefix = standardPrefixBeforeCursor(in: element) { return prefix }
        return webPrefixBeforeCursor(in: element)
    }

    private static func standardPrefixBeforeCursor(in element: AXUIElement) -> String? {
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selected) == .success,
              let selected, CFGetTypeID(selected) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(selected, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        if range.location == 0 { return "" }
        let length = min(max(range.location, 0), maximumPrefixLength)
        var requested = CFRange(location: max(0, range.location - length), length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &requested) else { return nil }
        var string: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &string) == .success else { return nil }
        return string as? String
    }

    /// Chromium/Electron contenteditable controls use web text markers instead
    /// of the CFRange-based attributes used by AppKit. Convert only the caret and
    /// the preceding bounded index to markers; never request the whole editor.
    private static func webPrefixBeforeCursor(in element: AXUIElement) -> String? {
        let selectedMarkerRangeAttribute = "AXSelectedTextMarkerRange" as CFString
        let indexForMarkerAttribute = "AXIndexForTextMarker" as CFString
        let markerForIndexAttribute = "AXTextMarkerForIndex" as CFString
        let stringForMarkerRangeAttribute = "AXStringForTextMarkerRange" as CFString

        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, selectedMarkerRangeAttribute, &selectedValue) == .success,
              let selectedValue,
              CFGetTypeID(selectedValue) == AXTextMarkerRangeGetTypeID() else { return nil }

        let selectedRange = unsafeBitCast(selectedValue, to: AXTextMarkerRange.self)
        let caretMarker = AXTextMarkerRangeCopyStartMarker(selectedRange)

        var indexValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, indexForMarkerAttribute, caretMarker, &indexValue) == .success,
              let caretIndex = (indexValue as? NSNumber)?.intValue else { return nil }
        if caretIndex == 0 { return "" }

        let lowerIndex = NSNumber(value: max(0, caretIndex - maximumPrefixLength))
        var lowerMarkerValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, markerForIndexAttribute, lowerIndex, &lowerMarkerValue) == .success,
              let lowerMarkerValue,
              CFGetTypeID(lowerMarkerValue) == AXTextMarkerGetTypeID() else { return nil }
        let lowerMarker = unsafeBitCast(lowerMarkerValue, to: AXTextMarker.self)
        let prefixRange = AXTextMarkerRangeCreate(kCFAllocatorDefault, lowerMarker, caretMarker)

        var stringValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, stringForMarkerRangeAttribute, prefixRange, &stringValue) == .success else {
            return nil
        }
        return stringValue as? String
    }

    private static func numberOfCharacters(in element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.intValue
    }
}
