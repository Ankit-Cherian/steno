import Foundation

/// Plans phrase replacements against one original text. Every match is found in the original,
/// overlapping matches are resolved longest-first, and the accepted replacements are applied in a
/// single pass, so text that a replacement produced is never matched again. Saved vocabulary and
/// text shortcuts both use it.
enum PhraseMatchPlanner {
    struct Match<Payload> {
        var range: NSRange
        var payload: Payload
    }

    private static let unspaced = "[" + WordFixLocator.unspacedScalars
        .map { String(format: "\\x{%X}-\\x{%X}", $0.lowerBound, $0.upperBound) }.joined() + "]"
    /// A letter, digit or underscore of a script that puts spaces between words. Chinese,
    /// Japanese and Thai letters are left out: next to one of them, a word can start or end.
    private static let wordCharacter = "[[\\p{L}\\p{N}_]--\(unspaced)]"
    private static let tokenJoiner = #"[.@/]"#

    /// A case-insensitive pattern for `phrase` with lookaround boundaries rather than `\b`, so
    /// phrases such as `C++`, `C#`, `.NET`, `v1.2` or `;sig` match on their own but never inside a
    /// longer token, an email address or a path. Whitespace inside the phrase matches any run of
    /// whitespace. Returns nil for a blank phrase.
    ///
    /// Chinese, Japanese, Thai and the other scripts written without spaces have no visible edge
    /// between words, so a phrase that starts or ends in one of them matches next to any letter
    /// on that side, as Fix a Word finds the word. It never ends before a combining mark, which
    /// belongs to the letter before it.
    static func regex(for phrase: String) -> NSRegularExpression? {
        let parts = phrase.split(whereSeparator: \.isWhitespace).map {
            NSRegularExpression.escapedPattern(for: String($0))
        }
        guard parts.isEmpty == false, let first = phrase.first(where: { !$0.isWhitespace }),
              let last = phrase.last(where: { !$0.isWhitespace }) else { return nil }
        let body = parts.joined(separator: #"\s+"#)
        let start = WordFixLocator.isUnspaced(first) ? "" : "(?<!\(wordCharacter))"
        let end = WordFixLocator.isUnspaced(last) ? #"(?!\p{M})"# : "(?!\(wordCharacter))"
        let pattern = start + "(?<![\\p{L}\\p{N}]\(tokenJoiner))"
            + body
            + end + "(?!\(tokenJoiner)[\\p{L}\\p{N}])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Keeps a set of non-overlapping matches: the longer match wins, then the one that starts
    /// first, then the one `ranksFirst` prefers. Returned in text order.
    static func resolveOverlaps<Payload>(
        _ matches: [Match<Payload>],
        ranksFirst: (Payload, Payload) -> Bool
    ) -> [Match<Payload>] {
        let ordered = matches.sorted { lhs, rhs in
            if lhs.range.length != rhs.range.length { return lhs.range.length > rhs.range.length }
            if lhs.range.location != rhs.range.location { return lhs.range.location < rhs.range.location }
            return ranksFirst(lhs.payload, rhs.payload)
        }

        var accepted: [Match<Payload>] = []
        for candidate in ordered where accepted.allSatisfy({ NSIntersectionRange($0.range, candidate.range).length == 0 }) {
            accepted.append(candidate)
        }
        return accepted.sorted { $0.range.location < $1.range.location }
    }

    /// Replaces each range of the original `text` with its replacement, in one pass. The ranges
    /// must not overlap.
    static func apply(_ replacements: [(range: NSRange, replacement: String)], to text: String) -> String {
        guard replacements.isEmpty == false else { return text }
        let source = text as NSString
        let result = NSMutableString(capacity: source.length)
        var copiedUpTo = 0
        for (range, replacement) in replacements.sorted(by: { $0.range.location < $1.range.location }) {
            result.append(source.substring(with: NSRange(location: copiedUpTo, length: range.location - copiedUpTo)))
            result.append(replacement)
            copiedUpTo = NSMaxRange(range)
        }
        result.append(source.substring(from: copiedUpTo))
        return String(result)
    }
}
