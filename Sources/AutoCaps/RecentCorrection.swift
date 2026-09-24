import Foundation

/// Only the latest replacement is retained, transiently. No history or storage.
struct RecentCorrection: Equatable {
    let original: String
    let replacement: String
    let suffix: String

    var emitted: String { replacement + suffix }

    func restoredText(removingSpace: Bool) -> String {
        original + (removingSpace && suffix.last == " " ? String(suffix.dropLast()) : suffix)
    }

    func undoEdit(removingSpace: Bool) -> TextEdit {
        TextEdit(backspaces: emitted.count, insertion: restoredText(removingSpace: removingSpace))
    }
}
