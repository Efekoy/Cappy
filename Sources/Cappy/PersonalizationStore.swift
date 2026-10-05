import Foundation

/// Stores only bounded correction-pair counters. It never stores surrounding
/// text, document contents, or sentence history.
final class PersonalizationStore {
    static let shared = PersonalizationStore()

    private static let rejectedKey = "personalization.rejectedPairs"
    private static let acceptedKey = "personalization.acceptedPairs"
    private static let separator = "\u{1F}"
    private static let maximumPairs = 512
    private let defaults: UserDefaults
    private var rejected: [String: Int]
    private var accepted: [String: Int]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rejected = defaults.dictionary(forKey: Self.rejectedKey) as? [String: Int] ?? [:]
        accepted = defaults.dictionary(forKey: Self.acceptedKey) as? [String: Int] ?? [:]
    }

    func shouldSuppress(original: String, replacement: String) -> Bool {
        let key = pairKey(original: original, replacement: replacement)
        let rejectedCount = rejected[key, default: 0]
        return rejectedCount >= 2 && rejectedCount > accepted[key, default: 0]
    }

    func recordAccepted(original: String, replacement: String) {
        increment(&accepted, key: pairKey(original: original, replacement: replacement))
        persist()
    }

    func recordRejected(original: String, replacement: String) {
        increment(&rejected, key: pairKey(original: original, replacement: replacement))
        persist()
    }

    private func pairKey(original: String, replacement: String) -> String {
        original.lowercased() + Self.separator + replacement.lowercased()
    }

    private func increment(_ dictionary: inout [String: Int], key: String) {
        dictionary[key] = min(dictionary[key, default: 0] + 1, 1_000)
        if dictionary.count > Self.maximumPairs,
           let leastUsed = dictionary.min(by: { $0.value < $1.value })?.key {
            dictionary.removeValue(forKey: leastUsed)
        }
    }

    private func persist() {
        defaults.set(rejected, forKey: Self.rejectedKey)
        defaults.set(accepted, forKey: Self.acceptedKey)
    }
}

/// Explicit user vocabulary, independent of automatic rejection learning.
/// One word per line; comments begin with #. File edits are watched, not polled.
final class ProtectedWords {
    static let shared = ProtectedWords()
    static let userFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cappy/never-autocorrect.txt")
    private(set) var words: Set<String> = []
    private let url: URL
    private let defaultsURL: URL?
    private var watcher: DispatchSourceFileSystemObject?

    init(url: URL = ProtectedWords.userFileURL, defaultsURL: URL? = Bundle.main.url(forResource: "NeverAutocorrect", withExtension: "txt"), watch: Bool = true) {
        self.url = url
        self.defaultsURL = defaultsURL
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            let initial = (defaultsURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) })
                ?? "# One word per line. Matching ignores case.\n# Words here are never autocorrected or capitalised.\nCappy\n"
            try? initial.write(to: url, atomically: true, encoding: .utf8)
        }
        reload()
        if watch {
            let descriptor = open(directory.path, O_EVTONLY)
            if descriptor >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
                source.setEventHandler { [weak self] in self?.reload() }
                source.setCancelHandler { close(descriptor) }
                watcher = source
                source.resume()
            }
        }
    }

    deinit { watcher?.cancel() }

    func reload() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        words = Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            let word = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !word.isEmpty, !word.contains(where: \.isWhitespace) else { return nil }
            return word
        })
    }

    func suppresses(original: String, replacement: String) -> Bool {
        // Never rewrite a contextual span containing an explicitly protected word.
        original.split(whereSeparator: \.isWhitespace).contains { words.contains($0.lowercased()) }
    }
}
