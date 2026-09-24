import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let eventTap = EventTapController()
    private var globalHotKey: GlobalHotKey?
    private var statusItem: NSStatusItem!
    private var setupWindow: SetupWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        globalHotKey = GlobalHotKey { [weak self] in self?.toggleEnabledFromHotkey() }
        if globalHotKey == nil {
            present(error: "The ⌃⌥⌘A shortcut could not be registered because another app is already using it.")
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeApplicationChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        Permissions.allGranted ? completeSetupAndStart() : showSetup()
    }
    func applicationWillTerminate(_ notification: Notification) {
        eventTap.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }
    @objc private func activeApplicationChanged() { eventTap.invalidateContext() }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "textformat.size.larger", accessibilityDescription: "AutoCaps")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        menu.addItem(toggleItem(title: settings.enabled ? "AutoCaps: On (⌃⌥⌘A)" : "AutoCaps: Off (⌃⌥⌘A)", state: settings.enabled, action: #selector(toggleEnabled)))
        menu.addItem(.separator())
        let parent = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(toggleItem(title: "Auto Capitalisation", state: settings.autoCapitalisation, action: #selector(toggleCapitalisation)))
        submenu.addItem(toggleItem(title: "Double-Space Period", state: settings.doubleSpacePeriod, action: #selector(toggleDoubleSpace)))
        submenu.addItem(toggleItem(title: "Contractions", state: settings.contractions, action: #selector(toggleContractions)))
        submenu.addItem(toggleItem(title: "Typo Fixes", state: settings.typoFixes, action: #selector(toggleTypoFixes)))
        submenu.addItem(.separator())
        submenu.addItem(toggleItem(title: "Launch at Login", state: settings.launchAtLogin, action: #selector(toggleLaunchAtLogin)))
        parent.submenu = submenu
        menu.addItem(parent)
        let permissionsItem = NSMenuItem(title: Permissions.allGranted ? "Permissions Status: Ready" : "Permissions Status: Action Required", action: #selector(showPermissions), keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit AutoCaps", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func toggleItem(title: String, state: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = state ? .on : .off
        return item
    }
    private func showSetup() {
        if setupWindow == nil { setupWindow = SetupWindowController { [weak self] in self?.completeSetupAndStart() } }
        setupWindow?.showWindow(nil)
    }
    private func completeSetupAndStart() {
        if !settings.setupCompleted {
            settings.setupCompleted = true
            do { try settings.setLaunchAtLogin(true) }
            catch { present(error: "AutoCaps could not enable Launch at Login. You can retry from the menu.") }
        }
        _ = eventTap.start()
        rebuildMenu()
    }
    private func present(error message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "AutoCaps"
        alert.informativeText = message
        alert.runModal()
    }
    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        if Permissions.allGranted { _ = eventTap.start() } else { showSetup() }
        eventTap.invalidateContext()
        rebuildMenu()
    }
    private func toggleEnabledFromHotkey() {
        settings.enabled.toggle()
        eventTap.invalidateContext()
        rebuildMenu()
    }
    @objc private func toggleCapitalisation() { settings.autoCapitalisation.toggle(); eventTap.invalidateContext(); rebuildMenu() }
    @objc private func toggleDoubleSpace() { settings.doubleSpacePeriod.toggle(); eventTap.invalidateContext(); rebuildMenu() }
    @objc private func toggleContractions() { settings.contractions.toggle(); eventTap.invalidateContext(); rebuildMenu() }
    @objc private func toggleTypoFixes() { settings.typoFixes.toggle(); eventTap.invalidateContext(); rebuildMenu() }
    @objc private func toggleLaunchAtLogin() {
        do { try settings.setLaunchAtLogin(!settings.launchAtLogin) }
        catch { present(error: "Launch at Login could not be changed. macOS may require approval in System Settings → General → Login Items.") }
        rebuildMenu()
    }
    @objc private func showPermissions() { showSetup(); setupWindow?.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }
}
