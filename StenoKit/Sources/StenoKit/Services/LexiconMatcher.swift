import Foundation

/// Applies saved vocabulary corrections to a transcript.
///
/// Every match is planned against the original text, overlaps are resolved longest-first, and
/// the accepted replacements are applied in one pass, so a replacement's output is never matched
/// again. Rules, in order of precedence for overlapping matches:
/// 1. The longer match wins, then the one that starts first.
/// 2. An existing occurrence of an entry's preferred spelling is protected and left as written,
///    unless another entry explicitly replaces exactly that text.
/// 3. For the same span, an app-scoped entry beats a global one, then the entry with the longer
///    spoken form, then the entry saved first.
///
/// Term boundaries are lookarounds rather than `\b`, so terms such as `C++`, `C#`, `.NET` and
/// `v1.2` match on their own but never inside a longer token.
public struct LexiconMatcher: Sendable {
    private struct Pattern: @unchecked Sendable {
        var regex: NSRegularExpression
        var variant: String
        var preferred: String
        var rank: Int
        var isProtectedSpelling: Bool
    }

    private struct PlannedMatch {
        var range: NSRange
        var pattern: Pattern
    }

    private let patterns: [Pattern]

    public init(lexicon: PersonalLexicon) {
        var patterns: [Pattern] = []
        for (rank, entry) in Self.resolvedEntries(lexicon.entries).enumerated() {
            let preferred = entry.preferred.trimmingCharacters(in: .whitespacesAndNewlines)
            let variants = Self.spokenVariants(for: entry)
            var coversPreferredSpelling = false

            for variant in variants {
                if variant.caseInsensitiveCompare(preferred) == .orderedSame {
                    coversPreferredSpelling = true
                }
                if LexiconSafety.shouldSkipLiteralReplacement(entry: entry, variant: variant) {
                    continue
                }
                guard let regex = Self.regex(for: variant) else { continue }
                patterns.append(Pattern(
                    regex: regex,
                    variant: variant,
                    preferred: preferred,
                    rank: rank,
                    isProtectedSpelling: false
                ))
            }

            if coversPreferredSpelling == false, let regex = Self.regex(for: preferred) {
                patterns.append(Pattern(
                    regex: regex,
                    variant: preferred,
                    preferred: preferred,
                    rank: rank,
                    isProtectedSpelling: true
                ))
            }
        }
        self.patterns = patterns
    }

    public func apply(to text: String) -> LexiconApplicationResult {
        guard text.isEmpty == false, patterns.isEmpty == false else {
            return LexiconApplicationResult(text: text, edits: [])
        }

        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        var planned: [PlannedMatch] = []
        for pattern in patterns {
            for match in pattern.regex.matches(in: text, range: fullRange) {
                planned.append(PlannedMatch(range: match.range, pattern: pattern))
            }
        }

        planned.sort { lhs, rhs in
            if lhs.range.length != rhs.range.length { return lhs.range.length > rhs.range.length }
            if lhs.range.location != rhs.range.location { return lhs.range.location < rhs.range.location }
            if lhs.pattern.isProtectedSpelling != rhs.pattern.isProtectedSpelling {
                return rhs.pattern.isProtectedSpelling
            }
            return lhs.pattern.rank < rhs.pattern.rank
        }

        var accepted: [PlannedMatch] = []
        for candidate in planned where accepted.allSatisfy({ NSIntersectionRange($0.range, candidate.range).length == 0 }) {
            accepted.append(candidate)
        }

        let replacements = accepted
            .filter { $0.pattern.isProtectedSpelling == false }
            .filter { source.substring(with: $0.range) != $0.pattern.preferred }
            .sorted { $0.range.location < $1.range.location }
        guard replacements.isEmpty == false else {
            return LexiconApplicationResult(text: text, edits: [])
        }

        let updated = NSMutableString(string: text)
        for replacement in replacements.reversed() {
            updated.replaceCharacters(in: replacement.range, with: replacement.pattern.preferred)
        }

        var edits: [TranscriptEdit] = []
        var seen: Set<String> = []
        for replacement in replacements {
            let key = replacement.pattern.variant.lowercased() + "\u{0}" + replacement.pattern.preferred
            guard seen.insert(key).inserted else { continue }
            edits.append(TranscriptEdit(
                kind: .lexiconCorrection,
                from: replacement.pattern.variant,
                to: replacement.pattern.preferred
            ))
        }

        return LexiconApplicationResult(text: String(updated), edits: edits)
    }

    /// The entries that can apply, in precedence order. Entries that can never fire (blank term or
    /// spelling, or an app scope with no bundle ID) are dropped, and an entry whose spoken form
    /// repeats one already claimed by a higher-precedence entry is dropped too, so an app-scoped
    /// entry replaces a global entry for the same term. Recognition hints use the same order.
    public static func resolvedEntries(_ entries: [LexiconEntry]) -> [LexiconEntry] {
        var claimedTerms: Set<String> = []
        return precedenceOrder(entries).filter { claimedTerms.insert(normalizedSpokenForm($0.term)).inserted }
    }

    /// Usable entries sorted by precedence: app scope first, then the longest spoken form, then
    /// saved order.
    static func precedenceOrder(_ entries: [LexiconEntry]) -> [LexiconEntry] {
        entries.enumerated()
            .filter { isUsable($0.element) }
            .sorted { lhs, rhs in
                let lhsScope = scopeRank(lhs.element.scope)
                let rhsScope = scopeRank(rhs.element.scope)
                if lhsScope != rhsScope { return lhsScope < rhsScope }
                let lhsKey = spokenLengthKey(lhs.element)
                let rhsKey = spokenLengthKey(rhs.element)
                if lhsKey != rhsKey { return lhsKey > rhsKey }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    static func isUsable(_ entry: LexiconEntry) -> Bool {
        guard entry.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              entry.preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return false
        }
        if case .app(let bundleID) = entry.scope,
           bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return true
    }

    /// Lowercased, whitespace-collapsed form used to compare spoken forms across entries.
    static func normalizedSpokenForm(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The spoken forms an entry replaces: its term, its aliases, and spaced forms of camel-case
    /// or hyphenated spellings (`StenoKit` also matches "steno kit"), longest first.
    static func spokenVariants(for entry: LexiconEntry) -> [String] {
        var variants = [entry.term]
        variants.append(contentsOf: entry.aliases)

        for source in [entry.term, entry.preferred] {
            let spaced = source
                .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
                .replacingOccurrences(of: #"[-_/]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if spaced.caseInsensitiveCompare(source) != .orderedSame {
                variants.append(spaced)
            }
        }

        var seen: Set<String> = []
        return variants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .filter { seen.insert(normalizedSpokenForm($0)).inserted }
    }

    private static func scopeRank(_ scope: Scope) -> Int {
        switch scope {
        case .app:
            return 0
        case .global:
            return 1
        }
    }

    private static func spokenLengthKey(_ entry: LexiconEntry) -> Int {
        ([entry.term] + entry.aliases).map { normalizedSpokenForm($0).count }.max() ?? 0
    }

    private static let wordCharacter = #"[\p{L}\p{N}_]"#
    private static let tokenJoiner = #"[.@/]"#

    private static func regex(for phrase: String) -> NSRegularExpression? {
        let parts = phrase.split(whereSeparator: \.isWhitespace).map {
            NSRegularExpression.escapedPattern(for: String($0))
        }
        guard parts.isEmpty == false else { return nil }
        let body = parts.joined(separator: #"\s+"#)
        let pattern = "(?<!\(wordCharacter))(?<![\\p{L}\\p{N}]\(tokenJoiner))"
            + body
            + "(?!\(wordCharacter))(?!\(tokenJoiner)[\\p{L}\\p{N}])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
