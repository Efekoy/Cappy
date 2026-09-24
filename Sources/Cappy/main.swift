import AppKit
import Carbon.HIToolbox
import InputMethodKit

if CommandLine.arguments.contains("--register-input-source") {
    let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
    print("Cappy input-source registration status: \(status)")
    exit(status == noErr ? EXIT_SUCCESS : EXIT_FAILURE)
}

private let connectionName = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String
    ?? "com.efekoy.inputmethod.Cappy.Connection"
private let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.efekoy.inputmethod.Cappy"

// IMKServer must live for the lifetime of the process. It creates one
// CappyInputController for each client input session.
let inputMethodServer = IMKServer(name: connectionName, bundleIdentifier: bundleIdentifier)
DispatchQueue.main.async {
    NativeSpellingCandidates.prepare()
}
NSApplication.shared.run()
