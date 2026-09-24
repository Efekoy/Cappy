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
