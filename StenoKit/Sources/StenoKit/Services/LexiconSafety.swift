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

/// How a saved vocabulary entry behaves when cleanup runs.
public enum LexiconEntryStatus: Sendable, Equatable {
    /// The entry applies. `keptSpokenForms` lists forms Steno always keeps as spoken.
    case active(keptSpokenForms: [String])
    /// Every spoken form is a common word Steno always keeps as spoken, so the entry never applies.
    case keptAsSpoken(spokenForms: [String])
    /// App scope without a bundle ID, which never matches an app.
    case missingApp
    /// Another entry in the same scope claims the same spoken form with a different spelling and
    /// takes precedence.
    case conflict(with: LexiconEntry)
}

/// The result of checking a new vocabulary entry before it is saved.
public struct LexiconEntryReview: Sendable, Equatable {
    public enum Rejection: Sendable, Equatable {
        case blankTerm
        case blankSpelling
        case missingApp
        /// An entry for the same spoken form in the same scope exists, written differently.
        case duplicate(existing: LexiconEntry)
    }

    public var rejection: Rejection?
    /// Spoken forms that are common English words and would be replaced in every dictation.
    public var commonWords: [String]
    /// Spoken forms Steno always keeps as spoken, so they will not be replaced.
    public var keptSpokenForms: [String]

    public var needsConfirmation: Bool {
        rejection == nil && (commonWords.isEmpty == false || keptSpokenForms.isEmpty == false)
    }
}

public enum LexiconEntryValidator {
    public static func review(_ candidate: LexiconEntry, existing: [LexiconEntry]) -> LexiconEntryReview {
        var review = LexiconEntryReview(rejection: nil, commonWords: [], keptSpokenForms: [])

        if candidate.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            review.rejection = .blankTerm
            return review
        }
        if candidate.preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            review.rejection = .blankSpelling
            return review
        }
        if case .app(let bundleID) = candidate.scope,
           bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            review.rejection = .missingApp
            return review
        }
        let spokenForm = LexiconMatcher.normalizedSpokenForm(candidate.term)
        if let duplicate = existing.first(where: {
            normalizedScope($0.scope) == normalizedScope(candidate.scope)
                && LexiconMatcher.normalizedSpokenForm($0.term) == spokenForm
                && $0.term != candidate.term
        }) {
            review.rejection = .duplicate(existing: duplicate)
            return review
        }

        review.keptSpokenForms = keptSpokenForms(of: candidate)
        review.commonWords = ([candidate.term] + candidate.aliases)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.split(whereSeparator: \.isWhitespace).count == 1 }
            .filter { $0.caseInsensitiveCompare(candidate.preferred) != .orderedSame }
            .filter { CommonEnglishWords.contains($0) }
            .filter { form in review.keptSpokenForms.contains { $0.caseInsensitiveCompare(form) == .orderedSame } == false }
        return review
    }

    public static func status(of entry: LexiconEntry, in entries: [LexiconEntry]) -> LexiconEntryStatus {
        if case .app(let bundleID) = entry.scope,
           bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .missingApp
        }

        let kept = keptSpokenForms(of: entry)
        let variants = LexiconMatcher.spokenVariants(for: entry)
        if variants.isEmpty == false, kept.count == variants.count {
            return .keptAsSpoken(spokenForms: kept)
        }

        let sameScope = LexiconMatcher.precedenceOrder(entries.filter { $0.scope == entry.scope })
        if let position = sameScope.firstIndex(of: entry) {
            let forms = Set(variants.map(LexiconMatcher.normalizedSpokenForm))
            let winner = sameScope[..<position].first { other in
                other.preferred != entry.preferred
                    && LexiconMatcher.spokenVariants(for: other)
                        .contains { forms.contains(LexiconMatcher.normalizedSpokenForm($0)) }
            }
            if let winner {
                return .conflict(with: winner)
            }
        }

        return .active(keptSpokenForms: kept)
    }

    private static func keptSpokenForms(of entry: LexiconEntry) -> [String] {
        LexiconMatcher.spokenVariants(for: entry).filter {
            LexiconSafety.shouldSkipLiteralReplacement(entry: entry, variant: $0)
        }
    }

    private static func normalizedScope(_ scope: Scope) -> Scope {
        switch scope {
        case .global:
            return .global
        case .app(let bundleID):
            return .app(bundleID: bundleID.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
