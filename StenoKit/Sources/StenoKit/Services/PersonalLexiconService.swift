import Foundation

public struct LexiconApplicationResult: Sendable, Equatable {
    public var text: String
    public var edits: [TranscriptEdit]

    public init(text: String, edits: [TranscriptEdit]) {
        self.text = text
        self.edits = edits
    }
}

public actor PersonalLexiconService {
    private var entries: [LexiconEntry]
    /// Compiled regexes keyed by lowercased term. Invalidated on mutation.
    private var regexCache: [String: NSRegularExpression] = [:]

    public init(entries: [LexiconEntry] = []) {
        self.entries = entries.sorted {
            Self.sortKey(for: $0) > Self.sortKey(for: $1)
        }
    }

    public func upsert(term: String, preferred: String, scope: Scope, aliases: [String] = []) {
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let cleanedAliases = aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let index = entries.firstIndex(where: {
            $0.term.caseInsensitiveCompare(term) == .orderedSame && $0.scope == scope
        }) {
            entries[index] = LexiconEntry(term: term, preferred: preferred, scope: scope, aliases: cleanedAliases)
        } else {
            entries.append(LexiconEntry(term: term, preferred: preferred, scope: scope, aliases: cleanedAliases))
        }

        entries.sort { Self.sortKey(for: $0) > Self.sortKey(for: $1) }
        regexCache.removeAll()
    }

    public func remove(term: String, scope: Scope) {
        entries.removeAll {
            $0.term.caseInsensitiveCompare(term) == .orderedSame && $0.scope == scope
        }
        regexCache.removeAll()
    }

    public func snapshot() -> PersonalLexicon {
        PersonalLexicon(entries: entries)
    }

    public func snapshot(for appContext: AppContext?) -> PersonalLexicon {
        PersonalLexicon(entries: filteredEntries(for: appContext))
    }

    public func apply(to text: String, appContext: AppContext?) -> String {
        applyWithEdits(to: text, appContext: appContext).text
    }

    public func applyWithEdits(to text: String, appContext: AppContext?) -> LexiconApplicationResult {
        guard !text.isEmpty else {
            return LexiconApplicationResult(text: text, edits: [])
        }

        // Entries are already sorted longest-first by the actor invariant.
        let applicable = filteredEntries(for: appContext)

        var updatedText = text
        var edits: [TranscriptEdit] = []

        for entry in applicable {
            let replacement = replaceEntryVariants(in: updatedText, entry: entry)
            if replacement.replacements > 0, replacement.text != updatedText {
                updatedText = replacement.text
                let matchedVariant = replacement.matchedVariant ?? entry.term
                if matchedVariant.caseInsensitiveCompare(entry.preferred) != .orderedSame {
                    edits.append(
                        TranscriptEdit(
                            kind: .lexiconCorrection,
                            from: matchedVariant,
                            to: entry.preferred
                        )
                    )
                }
            }
        }

        return LexiconApplicationResult(text: updatedText, edits: edits)
    }

    public func hotTerms(for appContext: AppContext?, limit: Int = 8) -> [String] {
        let applicable = filteredEntries(for: appContext).sorted { lhs, rhs in
            let lhsPriority = scopePriority(lhs.scope, appContext: appContext)
            let rhsPriority = scopePriority(rhs.scope, appContext: appContext)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return Self.sortKey(for: lhs) > Self.sortKey(for: rhs)
        }
        var ordered: [String] = []
        var seen: Set<String> = []

        for entry in applicable {
            let preferred = entry.preferred.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !preferred.isEmpty else { continue }
            let key = preferred.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            ordered.append(preferred)
            if ordered.count == max(0, limit) {
                break
            }
        }

        return ordered
    }

    private func filteredEntries(for appContext: AppContext?) -> [LexiconEntry] {
        entries.filter { entry in
            switch entry.scope {
            case .global:
                true
            case .app(let bundleID):
                bundleID == appContext?.bundleIdentifier
            }
        }
    }

    private func replaceEntryVariants(
        in text: String,
        entry: LexiconEntry
    ) -> (text: String, replacements: Int, matchedVariant: String?) {
        var updated = text
        var totalReplacements = 0
        var matchedVariant: String?

        for variant in entryVariants(for: entry) {
            let replacement = replaceWholePhrase(
                in: updated,
                variant: variant,
                preferred: entry.preferred
            )
            if replacement.replacements > 0 {
                updated = replacement.text
                totalReplacements += replacement.replacements
                matchedVariant = matchedVariant ?? variant
            }
        }

        return (updated, totalReplacements, matchedVariant)
    }

    private func replaceWholePhrase(
        in text: String,
        variant: String,
        preferred: String
    ) -> (text: String, replacements: Int) {
        let cacheKey = variant.lowercased()
        let regex: NSRegularExpression
        if let cached = regexCache[cacheKey] {
            regex = cached
        } else {
            let escaped = NSRegularExpression.escapedPattern(for: variant)
            let regexPattern = "\\b\(escaped)\\b"
            guard let compiled = try? NSRegularExpression(pattern: regexPattern, options: [.caseInsensitive]) else {
                return (text, 0)
            }
            regexCache[cacheKey] = compiled
            regex = compiled
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matchCount = regex.numberOfMatches(in: text, range: nsRange)
        guard matchCount > 0 else {
            return (text, 0)
        }

        let safeReplacement = NSRegularExpression.escapedTemplate(for: preferred)
        let replaced = regex.stringByReplacingMatches(in: text, range: nsRange, withTemplate: safeReplacement)
        return (replaced, matchCount)
    }

    private func entryVariants(for entry: LexiconEntry) -> [String] {
        var variants = [entry.term]
        variants.append(contentsOf: entry.aliases)

        let generated = generatedVariants(for: entry)
        variants.append(contentsOf: generated)

        var seen: Set<String> = []
        return variants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private func generatedVariants(for entry: LexiconEntry) -> [String] {
        var variants: [String] = []
        for source in [entry.term, entry.preferred] {
            let spaced = source
                .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
                .replacingOccurrences(of: #"[-_/]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if spaced.caseInsensitiveCompare(source) != .orderedSame {
                variants.append(spaced)
            }
        }
        return variants
    }

    private static func sortKey(for entry: LexiconEntry) -> Int {
        ([entry.term] + entry.aliases).map(\.count).max() ?? entry.term.count
    }

    private func scopePriority(_ scope: Scope, appContext: AppContext?) -> Int {
        switch scope {
        case .app(let bundleID) where bundleID == appContext?.bundleIdentifier:
            return 0
        case .global:
            return 1
        default:
            return 2
        }
    }
}
