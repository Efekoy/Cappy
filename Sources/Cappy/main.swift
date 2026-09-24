import AppKit
import InputMethodKit

private let connectionName = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String
    ?? "com.efekoy.Cappy.InputMethodConnection"
private let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.efekoy.Cappy"

// IMKServer must live for the lifetime of the process. It creates one
// CappyInputController for each client input session.
let inputMethodServer = IMKServer(name: connectionName, bundleIdentifier: bundleIdentifier)
NSApplication.shared.run()
