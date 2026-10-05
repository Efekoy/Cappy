import Foundation

struct PersonalCorrectionRecord: Codable, Equatable {
    var source: String
    var replacement: String
    var context: String
    var automaticAccepted = 0
    var automaticUndone = 0
    var suggestionsAccepted = 0
    var suggestionsRejected = 0
    var suggestionsIgnored = 0
    var lastInteraction = Date()
    var explicitlySuppressed: Bool? = nil
}
enum PersonalInteraction { case automaticAccepted, automaticUndone, suggestionAccepted, suggestionRejected, suggestionIgnored }
enum VocabularyState: String { case unknown, observed, likelyIntentional, protected }

/// Bounded local pair statistics and intentional token observations. No sentences
/// or document IDs are saved. Writes are coalesced off the keyboard hot path.
final class PersonalizationStore {
    static let shared = PersonalizationStore()
    private let defaults: UserDefaults
    private(set) var records: [String: PersonalCorrectionRecord] = [:]
    private(set) var vocabulary: [String: Int] = [:]
    private var pendingWrite: DispatchWorkItem?
    private static let storageKey = "personalization.v2"
    private static let vocabularyKey = "personalization.vocabulary.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([String: PersonalCorrectionRecord].self, from: data) {
            records = stored
        } else {
            // Migrate old pair counters once, retaining the user's rejections.
            for (storage, accepted) in [("personalization.acceptedPairs", true), ("personalization.rejectedPairs", false)] {
                for (key, count) in defaults.dictionary(forKey: storage) as? [String: Int] ?? [:] {
                    let parts = key.components(separatedBy: "\u{1F}")
                    guard parts.count == 2 else { continue }
                    let newKey = pairKey(parts[0], parts[1], "")
                    var record = records[newKey] ?? PersonalCorrectionRecord(source: parts[0], replacement: parts[1], context: "")
                    if accepted { record.automaticAccepted = count } else { record.automaticUndone = count }
                    records[newKey] = record
                }
            }
        }
        vocabulary = defaults.dictionary(forKey: Self.vocabularyKey) as? [String: Int] ?? [:]
        trim()
    }

    private func pairKey(_ source: String, _ replacement: String, _ context: String) -> String {
        source.lowercased() + "\u{1F}" + replacement.lowercased() + "\u{1F}" + context
    }
    static func contextSignature(_ tokens: [String]) -> String {
        // Stable bounded FNV hash of two preceding tokens, never plaintext context.
        guard !tokens.isEmpty else { return "" }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in tokens.suffix(2).joined(separator: " ").lowercased().utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
    func record(_ interaction: PersonalInteraction, original: String, replacement: String, context: String = "") {
        guard original.utf16.count <= 128, replacement.utf16.count <= 128 else { return }
        let key = pairKey(original, replacement, context)
        var item = records[key] ?? PersonalCorrectionRecord(source: original, replacement: replacement, context: context)
        switch interaction {
        case .automaticAccepted: item.automaticAccepted = min(1000, item.automaticAccepted + 1)
        case .automaticUndone: item.automaticUndone = min(1000, item.automaticUndone + 1)
        case .suggestionAccepted: item.suggestionsAccepted = min(1000, item.suggestionsAccepted + 1)
        case .suggestionRejected: item.suggestionsRejected = min(1000, item.suggestionsRejected + 1)
        case .suggestionIgnored: item.suggestionsIgnored = min(1000, item.suggestionsIgnored + 1)
        }
        item.lastInteraction = Date(); records[key] = item; trim(); schedulePersistence()
    }
    func recordAccepted(original: String, replacement: String) { record(.automaticAccepted, original: original, replacement: replacement) }
    func recordRejected(original: String, replacement: String) { record(.automaticUndone, original: original, replacement: replacement) }
    func adjustment(original: String, replacement: String, context: String = "") -> Double {
        let global = records[pairKey(original, replacement, "")]
        let contextual = context.isEmpty ? nil : records[pairKey(original, replacement, context)]
        return max(-0.6, min(0.20, [global, contextual].compactMap { $0 }.reduce(0) { sum, record in
            let accepted = record.automaticAccepted + record.suggestionsAccepted
            let positive = accepted >= 6 ? min(0.20, Double(accepted - 5) * 0.02) : 0
            let negative = Double(record.automaticUndone) * 0.09 + Double(record.suggestionsRejected) * 0.065 + Double(record.suggestionsIgnored) * 0.008
            return sum + positive - negative
        }))
    }
    func shouldSuppress(original: String, replacement: String, context: String = "") -> Bool {
        for signature in Set(["", context]) {
            guard let record = records[pairKey(original, replacement, signature)] else { continue }
            if record.explicitlySuppressed == true { return true }
            let rejects = record.automaticUndone + record.suggestionsRejected
            if rejects >= 3 && rejects > record.automaticAccepted + record.suggestionsAccepted { return true }
        }
        return false
    }
    func observeIntentional(_ token: String, unfamiliar: Bool = false) {
        guard token.count >= 2, token.count <= 32, token.allSatisfy(\.isLetter),
              unfamiliar || token == token.uppercased() || !ContextualPhraseRanker.simple(token) else { return }
        vocabulary[token] = min(20, vocabulary[token, default: 0] + 1)
        trim(); schedulePersistence()
    }
    func vocabularyState(_ token: String, protectedWords: ProtectedWords) -> VocabularyState {
        if protectedWords.words.contains(token.lowercased()) { return .protected }
        let count = vocabulary[token, default: 0]
        return count >= 8 ? .likelyIntentional : count > 0 ? .observed : .unknown
    }
    func suppressPair(original: String, replacement: String, context: String) {
        let key = pairKey(original, replacement, context)
        var record = records[key] ?? PersonalCorrectionRecord(source: original, replacement: replacement, context: context)
        record.explicitlySuppressed = true; record.lastInteraction = Date()
        records[key] = record; trim(); schedulePersistence()
    }
    func removeRecord(_ key: String) { records.removeValue(forKey: key); schedulePersistence() }
    func removeVocabulary(_ word: String) { vocabulary.removeValue(forKey: word); schedulePersistence() }
    private func trim() {
        if records.count > 512 {
            for key in records.keys.sorted(by: { records[$0]!.lastInteraction < records[$1]!.lastInteraction }).prefix(records.count - 512) { records.removeValue(forKey: key) }
        }
        if vocabulary.count > 512 {
            for key in vocabulary.keys.sorted(by: { vocabulary[$0]! == vocabulary[$1]! ? $0 < $1 : vocabulary[$0]! < vocabulary[$1]! }).prefix(vocabulary.count - 512) { vocabulary.removeValue(forKey: key) }
        }
    }
    private func schedulePersistence() {
        pendingWrite?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.flush() }
        pendingWrite = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }
    func flush() {
        pendingWrite?.cancel(); pendingWrite = nil
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.storageKey) }
        defaults.set(vocabulary, forKey: Self.vocabularyKey)
        defaults.removeObject(forKey: "personalization.acceptedPairs")
        defaults.removeObject(forKey: "personalization.rejectedPairs")
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

    @discardableResult func protect(_ word: String) -> Bool {
        let token = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.count <= 32, token.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return false }
        reload()
        if words.contains(token.lowercased()) { return true }
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        return saveText(text + token + "\n")
    }
    @discardableResult func remove(_ word: String) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: "\n").filter { line in
            let value = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value != word.lowercased()
        }
        return saveText(lines.joined(separator: "\n"))
    }
    private func saveText(_ text: String) -> Bool {
        do { try text.write(to: url, atomically: true, encoding: .utf8); reload(); return true }
        catch { return false }
    }

    func suppresses(original: String, replacement: String) -> Bool {
        // Never rewrite a contextual span containing an explicitly protected word.
        original.split(whereSeparator: \.isWhitespace).contains { words.contains($0.lowercased()) }
    }
}
