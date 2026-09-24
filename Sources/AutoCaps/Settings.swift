import Foundation
import ServiceManagement

final class Settings {
    static let shared = Settings()
    private enum Key {
        static let enabled = "enabled"
        static let autoCapitalisation = "autoCapitalisation"
        static let doubleSpacePeriod = "doubleSpacePeriod"
        static let contractions = "contractions"
        static let typoFixes = "typoFixes"
        static let setupCompleted = "setupCompleted"
    }
    private let defaults = UserDefaults.standard
    private init() {
        defaults.register(defaults: [Key.enabled: true, Key.autoCapitalisation: true,
            Key.doubleSpacePeriod: true, Key.contractions: true,
            Key.typoFixes: true, Key.setupCompleted: false])
    }
    var enabled: Bool { get { defaults.bool(forKey: Key.enabled) } set { defaults.set(newValue, forKey: Key.enabled) } }
    var autoCapitalisation: Bool { get { defaults.bool(forKey: Key.autoCapitalisation) } set { defaults.set(newValue, forKey: Key.autoCapitalisation) } }
    var doubleSpacePeriod: Bool { get { defaults.bool(forKey: Key.doubleSpacePeriod) } set { defaults.set(newValue, forKey: Key.doubleSpacePeriod) } }
    var contractions: Bool { get { defaults.bool(forKey: Key.contractions) } set { defaults.set(newValue, forKey: Key.contractions) } }
    var typoFixes: Bool { get { defaults.bool(forKey: Key.typoFixes) } set { defaults.set(newValue, forKey: Key.typoFixes) } }
    var setupCompleted: Bool { get { defaults.bool(forKey: Key.setupCompleted) } set { defaults.set(newValue, forKey: Key.setupCompleted) } }
    var features: TypingFeatures { TypingFeatures(autoCapitalisation: autoCapitalisation, doubleSpacePeriod: doubleSpacePeriod, contractions: contractions, typoFixes: typoFixes) }
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
            try SMAppService.mainApp.unregister()
        }
    }
}
