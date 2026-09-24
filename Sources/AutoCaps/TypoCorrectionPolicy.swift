import Foundation

/// Pure validation layer between the system suggestion and synthetic keystrokes.
enum TypoCorrectionPolicy {
    static func accepted(original: String, suggestion: String) -> String? {
        guard !suggestion.isEmpty,
              suggestion != original,
              suggestion.count >= 2,
              suggestion.count <= 26,
              suggestion.unicodeScalars.allSatisfy({
                  CharacterSet.letters.contains($0) && $0.isASCII || $0 == "'"
              }),
              suggestion.filter({ $0 == "'" }).count <= 1,
              editDistanceAtMostTwo(original.lowercased(), suggestion.lowercased()) else {
            return nil
        }

        if original.first?.isUppercase == true {
            return suggestion.prefix(1).uppercased() + suggestion.dropFirst()
        }
        return suggestion.lowercased()
    }

    /// A bounded Damerau–Levenshtein check (including adjacent transpositions).
    /// Words are capped at 24 characters before this is called.
    private static func editDistanceAtMostTwo(_ first: String, _ second: String) -> Bool {
        let a = Array(first)
        let b = Array(second)
        if abs(a.count - b.count) > 2 { return false }

        var distance = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { distance[i][0] = i }
        for j in 0...b.count { distance[0][j] = j }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) <= 2 }

        for i in 1...a.count {
            for j in 1...b.count {
                let substitution = a[i - 1] == b[j - 1] ? 0 : 1
                distance[i][j] = min(
                    distance[i - 1][j] + 1,
                    distance[i][j - 1] + 1,
                    distance[i - 1][j - 1] + substitution
                )
                if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                    distance[i][j] = min(distance[i][j], distance[i - 2][j - 2] + 1)
                }
            }
        }
        return distance[a.count][b.count] <= 2
    }
}
