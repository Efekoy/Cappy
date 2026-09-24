import AppKit

final class SetupWindowController: NSWindowController {
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let inputStatus = NSTextField(labelWithString: "")
    private var completion: (() -> Void)?
    private var timer: Timer?

    init(completion: @escaping () -> Void) {
        self.completion = completion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 310),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set Up AutoCaps"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        refresh()
    }
    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        startTemporaryPermissionCheck()
    }

    func refresh() {
        accessibilityStatus.stringValue = Permissions.accessibilityGranted ? "✓ Accessibility granted" : "○ Accessibility required"
        inputStatus.stringValue = Permissions.inputMonitoringGranted ? "✓ Input Monitoring granted" : "○ Input Monitoring required"
        if Permissions.allGranted {
            timer?.invalidate()
            timer = nil
            window?.orderOut(nil)
            completion?()
        }
    }

    private func buildContent() {
        let title = NSTextField(labelWithString: "AutoCaps needs permission")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: "AutoCaps needs Accessibility permission to modify your typing across apps. AutoCaps does not store or transmit anything you type.")
        explanation.textColor = .secondaryLabelColor
        let axButton = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibility))
        let inputButton = NSButton(title: "Open Input Monitoring Settings", target: self, action: #selector(openInputMonitoring))
        let recheck = NSButton(title: "Check Again", target: self, action: #selector(checkAgain))
        recheck.keyEquivalent = "\r"
        let stack = NSStackView(views: [title, explanation, accessibilityStatus, axButton, inputStatus, inputButton, recheck])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window?.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            explanation.widthAnchor.constraint(equalToConstant: 382)
        ])
    }

    private func startTemporaryPermissionCheck() {
        timer?.invalidate()
        // The only polling in the app, active solely while one-time setup is visible.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    @objc private func openAccessibility() { Permissions.requestAccessibility(); Permissions.openAccessibilitySettings() }
    @objc private func openInputMonitoring() { Permissions.requestInputMonitoring(); Permissions.openInputMonitoringSettings() }
    @objc private func checkAgain() { refresh() }
}
