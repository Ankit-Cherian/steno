import Foundation

public actor SnippetService {
    private var snippets: [Snippet]
    /// Compiled regexes keyed by lowercased trigger. Invalidated on mutation.
    private var regexCache: [String: NSRegularExpression] = [:]

    public init(snippets: [Snippet] = []) {
        self.snippets = snippets
    }

    public func upsert(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
        regexCache.removeAll()
    }

    public func remove(id: UUID) {
        snippets.removeAll { $0.id == id }
        regexCache.removeAll()
    }

    public func list() -> [Snippet] {
        snippets
    }

    public func apply(to text: String, appContext: AppContext?) -> String {
        guard !text.isEmpty else { return text }
        var updated = text

        for snippet in snippets {
            switch snippet.scope {
            case .global:
                updated = expand(snippet, in: updated)
            case .app(let bundleID):
                if bundleID == appContext?.bundleIdentifier {
                    updated = expand(snippet, in: updated)
                }
            }
        }

        return updated
    }

    private func expand(_ snippet: Snippet, in text: String) -> String {
        let cacheKey = snippet.trigger.lowercased()
        let regex: NSRegularExpression
        if let cached = regexCache[cacheKey] {
            regex = cached
        } else {
            let escaped = NSRegularExpression.escapedPattern(for: snippet.trigger)
            let pattern = "\\b\(escaped)\\b"
            guard let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return text
            }
            regexCache[cacheKey] = compiled
            regex = compiled
        }

        let range = NSRange(text.startIndex..., in: text)
        let safeExpansion = NSRegularExpression.escapedTemplate(for: snippet.expansion)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: safeExpansion)
    }
}
