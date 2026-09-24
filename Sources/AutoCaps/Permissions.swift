import AppKit
import ApplicationServices

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }
    static var allGranted: Bool { accessibilityGranted && inputMonitoringGranted }
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    static func requestInputMonitoring() { _ = CGRequestListenEventAccess() }
    static func openAccessibilitySettings() { openSettings(anchor: "Privacy_Accessibility") }
    static func openInputMonitoringSettings() { openSettings(anchor: "Privacy_ListenEvent") }
    private static func openSettings(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
}
