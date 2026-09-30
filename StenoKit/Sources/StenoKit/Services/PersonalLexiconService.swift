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

    public init(entries: [LexiconEntry] = []) {
        self.entries = PersonalLexicon.longestFirst(entries)
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

        entries = PersonalLexicon.longestFirst(entries)
    }

    public func remove(term: String, scope: Scope) {
        entries.removeAll {
            $0.term.caseInsensitiveCompare(term) == .orderedSame && $0.scope == scope
        }
    }

    public func snapshot() -> PersonalLexicon {
        PersonalLexicon(entries: entries)
    }

    public func snapshot(for appContext: AppContext?) -> PersonalLexicon {
        PersonalLexicon(entries: filteredEntries(for: appContext))
    }

    public func hotTerms(for appContext: AppContext?, limit: Int = 8) -> [String] {
        // Same precedence as cleanup, so the recognition hint and the applied correction agree.
        let applicable = LexiconMatcher.resolvedEntries(filteredEntries(for: appContext))
        var ordered: [String] = []
        var seen: Set<String> = []

        for entry in applicable {
            guard LexiconSafety.shouldExposeHotTerm(entry) else { continue }
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
}
