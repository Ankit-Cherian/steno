import Foundation

/// Expands spoken text shortcuts. Every trigger is matched against the text as recognized, so an
/// expansion is never expanded again, and overlapping triggers resolve the same way whatever order
/// they were saved in: the longer trigger wins, and for the same trigger an app shortcut beats an
/// all-apps one, then the shortcut saved first.
public actor SnippetService {
    private struct Rule: @unchecked Sendable {
        var regex: NSRegularExpression
        var expansion: String
        var rank: Int
    }

    private var snippets: [Snippet]
    /// Compiled rules per app, in precedence order. Invalidated on mutation.
    private var rulesCache: [String: [Rule]] = [:]

    public init(snippets: [Snippet] = []) {
        self.snippets = snippets
    }

    /// The trigger as it is matched: trimmed, or nil when nothing is left.
    public static func normalizedTrigger(_ trigger: String) -> String? {
        let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Adds or replaces a shortcut, with its trigger trimmed. A shortcut whose trigger is blank is
    /// rejected and not stored.
    @discardableResult
    public func upsert(_ snippet: Snippet) -> Bool {
        guard let trigger = Self.normalizedTrigger(snippet.trigger) else { return false }
        var stored = snippet
        stored.trigger = trigger
        if let index = snippets.firstIndex(where: { $0.id == stored.id }) {
            snippets[index] = stored
        } else {
            snippets.append(stored)
        }
        rulesCache.removeAll()
        return true
    }

    public func remove(id: UUID) {
        snippets.removeAll { $0.id == id }
        rulesCache.removeAll()
    }

    public func list() -> [Snippet] {
        snippets
    }

    public func apply(to text: String, appContext: AppContext?) -> String {
        guard !text.isEmpty else { return text }
        let rules = rules(for: appContext?.bundleIdentifier)
        guard rules.isEmpty == false else { return text }

        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        var planned: [PhraseMatchPlanner.Match<Rule>] = []
        for rule in rules {
            for match in rule.regex.matches(in: text, range: fullRange) {
                planned.append(PhraseMatchPlanner.Match(range: match.range, payload: rule))
            }
        }

        let accepted = PhraseMatchPlanner.resolveOverlaps(planned) { $0.rank < $1.rank }
        return PhraseMatchPlanner.apply(
            accepted.map { (range: $0.range, replacement: $0.payload.expansion) },
            to: text
        )
    }

    /// The shortcuts that apply in `bundleID`, one per trigger: app shortcuts first, then all-apps
    /// shortcuts, each in saved order.
    private func rules(for bundleID: String?) -> [Rule] {
        let key = bundleID ?? ""
        if let cached = rulesCache[key] { return cached }

        let applicable = snippets.enumerated().compactMap { offset, snippet -> (scopeRank: Int, offset: Int, snippet: Snippet)? in
            switch snippet.scope {
            case .global:
                return (1, offset, snippet)
            case .app(let appBundleID):
                guard let bundleID, appBundleID == bundleID else { return nil }
                return (0, offset, snippet)
            }
        }
        .sorted { ($0.scopeRank, $0.offset) < ($1.scopeRank, $1.offset) }

        var claimedTriggers: Set<String> = []
        var rules: [Rule] = []
        for (rank, item) in applicable.enumerated() {
            guard let trigger = Self.normalizedTrigger(item.snippet.trigger),
                  claimedTriggers.insert(LexiconMatcher.normalizedSpokenForm(trigger)).inserted,
                  let regex = PhraseMatchPlanner.regex(for: trigger)
            else {
                continue
            }
            rules.append(Rule(regex: regex, expansion: item.snippet.expansion, rank: rank))
        }
        rulesCache[key] = rules
        return rules
    }
}
