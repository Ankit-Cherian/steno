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

    /// Checks the correction Fix a word adds for future dictations, without adding it. The
    /// correction applies in every app. Throws when it can't be added as asked: a common word
    /// needs `confirmingCommonWord`, a word Steno always keeps as spoken would never be replaced,
    /// and an existing correction for the same word with another spelling takes precedence.
    public func reviewWordCorrection(
        original: String,
        replacement: String,
        confirmingCommonWord: Bool
    ) throws -> LexiconEntry {
        let candidate = LexiconEntry(
            term: original.trimmingCharacters(in: .whitespacesAndNewlines),
            preferred: replacement.trimmingCharacters(in: .whitespacesAndNewlines),
            scope: .global
        )
        let spokenForm = LexiconMatcher.normalizedSpokenForm(candidate.term)
        if let existing = entries.first(where: {
            $0.scope == .global
                && LexiconMatcher.normalizedSpokenForm($0.term) == spokenForm
                && $0.preferred != candidate.preferred
        }) {
            throw WordFixError.conflictingCorrection(existing: existing)
        }

        let review = LexiconEntryValidator.review(candidate, existing: entries)
        switch review.rejection {
        case nil:
            break
        case .duplicate(let existing):
            throw WordFixError.conflictingCorrection(existing: existing)
        case .blankTerm, .blankSpelling, .missingApp:
            throw WordFixError.invalidReplacement
        }
        if let kept = review.keptSpokenForms.first {
            throw WordFixError.keptAsSpoken(kept)
        }
        // The vocabulary review leaves out a word the correction changes only by case, but a
        // fix made from History still asks first: it would change the case of that common
        // word in every dictation.
        let caseOnlyCommonWord = candidate.term.split(whereSeparator: \.isWhitespace).count == 1
            && candidate.term != candidate.preferred
            && candidate.term.caseInsensitiveCompare(candidate.preferred) == .orderedSame
            && CommonEnglishWords.contains(candidate.term)
        if let common = review.commonWords.first ?? (caseOnlyCommonWord ? candidate.term : nil),
           !confirmingCommonWord {
            throw WordFixError.commonWord(common)
        }
        return candidate
    }

    /// Adds `entry`, replacing an entry for the same word and scope.
    /// Adds a correction. A correction that already exists with the same word, spelling and scope
    /// stays as configured, with its aliases and phonetic recovery.
    public func add(_ entry: LexiconEntry) {
        if entries.contains(where: {
            $0.term.caseInsensitiveCompare(entry.term) == .orderedSame
                && $0.preferred == entry.preferred
                && $0.scope == entry.scope
        }) {
            return
        }
        upsert(term: entry.term, preferred: entry.preferred, scope: entry.scope, aliases: entry.aliases)
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
