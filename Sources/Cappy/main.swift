import AppKit
import Carbon.HIToolbox
import InputMethodKit

if let index = CommandLine.arguments.firstIndex(of: "--evaluate"), CommandLine.arguments.count > index + 1 {
    do { try CorrectionEvaluationRunner.run(url: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(EXIT_SUCCESS) }
    catch { fputs("Evaluation failed: \(error)\n", stderr); exit(EXIT_FAILURE) }
}

if CommandLine.arguments.contains("--benchmark") {
    BenchmarkRunner.run()
    exit(EXIT_SUCCESS)
}

if CommandLine.arguments.contains("--register-input-source") {
    let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
    print("Cappy input-source registration status: \(status)")
    exit(status == noErr ? EXIT_SUCCESS : EXIT_FAILURE)
}

if CommandLine.arguments.contains("--settings") {
    PersonalisationSettingsController.shared.show()
    NSApplication.shared.run()
    exit(EXIT_SUCCESS)
}

private let connectionName = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String
    ?? "com.efekoy.inputmethod.Cappy.Connection"
private let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.efekoy.inputmethod.Cappy"

// IMKServer must live for the lifetime of the process. It creates one
// CappyInputController for each client input session.
let inputMethodServer = IMKServer(name: connectionName, bundleIdentifier: bundleIdentifier)
DispatchQueue.main.async {
    NativeSpellingCandidates.prepare()
    _ = WordFrequencyModel.shared
    _ = ContextReranker.shared
}
NSApplication.shared.run()
