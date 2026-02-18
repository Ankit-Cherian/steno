import Foundation

public actor SnippetService {
    private var snippets: [Snippet]

    public init(snippets: [Snippet] = []) {
        self.snippets = snippets
    }

    public func upsert(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
    }

    public func remove(id: UUID) {
        snippets.removeAll { $0.id == id }
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
        let escaped = NSRegularExpression.escapedPattern(for: snippet.trigger)
        let pattern = "\\b\(escaped)\\b"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: snippet.expansion)
    }
}
