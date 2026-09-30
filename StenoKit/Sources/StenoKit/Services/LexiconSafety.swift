import Foundation

enum LexiconSafety {
    private static let guardedCommonLiteralTerms: Set<String> = [
        "actually",
        "basic",
        "basically",
        "call",
        "cloud",
        "code",
        "kind",
        "like",
        "mail",
        "mean",
        "no",
        "note",
        "notes",
        "open",
        "period",
        "sort",
        "storage",
    ]

    static func shouldSkipLiteralReplacement(entry: LexiconEntry, variant: String) -> Bool {
        // Casing-only entries are guarded too: they now apply, and a guarded word must stay as spoken.
        let source = normalized(variant)
        guard source.isEmpty == false else { return false }
        guard source.split(separator: " ").count == 1 else { return false }
        return guardedCommonLiteralTerms.contains(source)
    }

    static func shouldExposeHotTerm(_ entry: LexiconEntry) -> Bool {
        let variants = [entry.term] + entry.aliases
        return variants.contains { shouldSkipLiteralReplacement(entry: entry, variant: $0) } == false
    }

    private static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\s]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
