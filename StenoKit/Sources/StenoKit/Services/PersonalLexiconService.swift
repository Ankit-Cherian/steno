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
        self.entries = entries.sorted { $0.term.count > $1.term.count }
    }

    public func upsert(term: String, preferred: String, scope: Scope) {
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if let index = entries.firstIndex(where: {
            $0.term.caseInsensitiveCompare(term) == .orderedSame && $0.scope == scope
        }) {
            entries[index] = LexiconEntry(term: term, preferred: preferred, scope: scope)
        } else {
            entries.append(LexiconEntry(term: term, preferred: preferred, scope: scope))
        }

        entries.sort { $0.term.count > $1.term.count }
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
            let replacement = replaceWholeWord(
                in: updatedText,
                entry: entry
            )
            if replacement.replacements > 0 {
                updatedText = replacement.text
                edits.append(
                    TranscriptEdit(
                        kind: .lexiconCorrection,
                        from: entry.term,
                        to: entry.preferred
                    )
                )
            }
        }

        return LexiconApplicationResult(text: updatedText, edits: edits)
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

    private func replaceWholeWord(
        in text: String,
        entry: LexiconEntry
    ) -> (text: String, replacements: Int) {
        let cacheKey = entry.term.lowercased()
        let regex: NSRegularExpression
        if let cached = regexCache[cacheKey] {
            regex = cached
        } else {
            let escaped = NSRegularExpression.escapedPattern(for: entry.term)
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

        let safeReplacement = NSRegularExpression.escapedTemplate(for: entry.preferred)
        let replaced = regex.stringByReplacingMatches(in: text, range: nsRange, withTemplate: safeReplacement)
        return (replaced, matchCount)
    }
}
