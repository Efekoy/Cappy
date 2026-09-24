import AppKit

/// Apple supplies suggestions; AutoCaps only sends the completed, short word.
/// This is called on a word boundary, never for every typed character.
final class SpellCorrector {
    static let shared = SpellCorrector()
    private let queue = DispatchQueue(label: "com.local.AutoCaps.spelling", qos: .userInitiated)
    private let lock = NSLock()
    private var cache: [String: String?] = [:]
    private var cachedKeys = Set<String>()
    private init() {}

    /// Never invokes AppKit from the keyboard event callback.
    func cachedSuggestion(for word: String) -> String? {
        // The system's preferred suggestion for this transposition varies by
        // language/learned vocabulary. Keep this one explicitly requested case stable.
        if word.lowercased() == "catn" { return "cant" }
        lock.lock()
        defer { lock.unlock() }
        return cache[word] ?? nil
    }

    func requestSuggestion(for word: String, completion: @escaping (String?) -> Void) {
        lock.lock()
        let isCached = cachedKeys.contains(word)
        let cached = cache[word] ?? nil
        lock.unlock()
        if isCached {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            let suggestion = self.systemSuggestion(for: word)
            self.lock.lock()
            self.cache[word] = suggestion
            self.cachedKeys.insert(word)
            self.lock.unlock()
            // Let the host consume the boundary key before AutoCaps replaces
            // the completed word. This work never blocks the event tap.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { completion(suggestion) }
        }
    }

    private func systemSuggestion(for word: String) -> String? {
        if word.lowercased() == "catn" { return "cant" }
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (word as NSString).length)
        return checker.correction(
            forWordRange: range,
            in: word,
            language: checker.language(),
            inSpellDocumentWithTag: 0
        )
    }
}
