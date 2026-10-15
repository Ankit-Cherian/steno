import Foundation

/// A word-level comparison of the recognized text and the cleaned text, for Before cleanup.
/// Words that only changed case or punctuation are compared by character, so "Um, move" →
/// "Move" reads as "Um," removed and "M" added rather than two whole words swapped.
enum CleanupDiff {
    enum Kind: Equatable, Sendable {
        case same
        case removed
        case added
    }

    struct Segment: Equatable, Sendable {
        var kind: Kind
        var text: String
    }

    static func segments(before: String, after: String) -> [Segment] {
        let old = tokens(before)
        let new = tokens(after)
        let ops = wordOperations(old, new)
        var segments: [Segment] = []
        var index = 0
        while index < ops.count {
            // A removed word followed by an added word that differs only in case or
            // punctuation is shown character by character.
            if case .removed(let removed) = ops[index], index + 1 < ops.count,
               case .added(let added) = ops[index + 1], loosely(removed) == loosely(added), !loosely(added).isEmpty {
                append(characterSegments(removed, added), to: &segments)
                index += 2
                continue
            }
            switch ops[index] {
            case .same(let word): append([Segment(kind: .same, text: word)], to: &segments)
            case .removed(let word): append([Segment(kind: .removed, text: word)], to: &segments)
            case .added(let word): append([Segment(kind: .added, text: word)], to: &segments)
            }
            index += 1
        }
        return segments
    }

    /// Words, each keeping the whitespace that follows it.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSpace = false
        for character in text {
            if character.isWhitespace {
                inSpace = true
                current.append(character)
            } else {
                if inSpace, !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                inSpace = false
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private enum Operation {
        case same(String), removed(String), added(String)
    }

    private static func comparable(_ token: String) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loosely(_ token: String) -> String {
        comparable(token).lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Longest-common-subsequence over words. Dictations are short, so O(n·m) is fine;
    /// very long texts fall back to one removed and one added block.
    private static func wordOperations(_ old: [String], _ new: [String]) -> [Operation] {
        guard old.count * new.count <= 4_000_000 else {
            return old.map { .removed($0) } + new.map { .added($0) }
        }
        let n = old.count, m = new.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = comparable(old[i]) == comparable(new[j])
                        ? table[i + 1][j + 1] + 1
                        : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var ops: [Operation] = []
        var i = 0, j = 0
        while i < n, j < m {
            if comparable(old[i]) == comparable(new[j]) {
                ops.append(.same(new[j])); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                ops.append(.removed(old[i])); i += 1
            } else {
                ops.append(.added(new[j])); j += 1
            }
        }
        while i < n { ops.append(.removed(old[i])); i += 1 }
        while j < m { ops.append(.added(new[j])); j += 1 }
        return ops
    }

    /// Common prefix and suffix kept, the differing middle shown as removed then added, so
    /// "move" → "Move" gives added "M", same "ove".
    private static func characterSegments(_ removed: String, _ added: String) -> [Segment] {
        let a = Array(removed), b = Array(added)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        var result: [Segment] = []
        if prefix > 0 { result.append(Segment(kind: .same, text: String(a[..<prefix]))) }
        let removedMiddle = String(a[prefix..<(a.count - suffix)])
        let addedMiddle = String(b[prefix..<(b.count - suffix)])
        // A change of case only shows the new letters; the struck letter would read as a deletion.
        if !removedMiddle.isEmpty, removedMiddle.lowercased() != addedMiddle.lowercased() {
            result.append(Segment(kind: .removed, text: removedMiddle))
        }
        if !addedMiddle.isEmpty { result.append(Segment(kind: .added, text: addedMiddle)) }
        if suffix > 0 { result.append(Segment(kind: .same, text: String(a[(a.count - suffix)...]))) }
        return result
    }

    /// Merges with the previous segment when the kind matches.
    private static func append(_ new: [Segment], to segments: inout [Segment]) {
        for segment in new where !segment.text.isEmpty {
            if let last = segments.last, last.kind == segment.kind {
                segments[segments.count - 1].text += segment.text
            } else {
                segments.append(segment)
            }
        }
    }

    /// Words changed by cleanup: removed plus added runs, counted once per run.
    static func changeCount(before: String, after: String) -> Int {
        segments(before: before, after: after).filter { $0.kind != .same }.count
    }
}
