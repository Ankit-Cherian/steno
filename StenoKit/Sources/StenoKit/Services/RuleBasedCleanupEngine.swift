import Foundation

public struct RuleBasedCleanupEngine: CleanupEngine, Sendable {
    public init() {}

    public func cleanup(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> CleanTranscript {
        let generator = RuleBasedCleanupCandidateGenerator()
        let candidates = try await generator.generateCandidates(
            raw: raw,
            profile: profile,
            lexicon: lexicon
        )
        let ranker = LocalCleanupRanker()
        let best = ranker.bestCandidate(
            rawText: raw.text,
            candidates: candidates,
            profile: profile
        )

        return CleanTranscript(
            text: best.text,
            edits: best.appliedEdits,
            removedFillers: best.removedFillers,
            uncertaintyFlags: []
        )
    }

    func buildCandidate(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon,
        rulePathID: String
    ) -> CleanupCandidate {
        var text = raw.text
        var edits: [TranscriptEdit] = []
        var removedFillers: [String] = []

        let fillerResult = removeFillers(from: text, policy: profile.fillerPolicy)
        text = fillerResult.text
        removedFillers = fillerResult.removed
        edits.append(contentsOf: fillerResult.edits)

        let lexiconResult = applyLexicon(text: text, lexicon: lexicon)
        text = lexiconResult.text
        edits.append(contentsOf: lexiconResult.edits)

        let structureResult = applyStructure(text: text, mode: profile.structureMode)
        text = structureResult.text
        edits.append(contentsOf: structureResult.edits)

        return CleanupCandidate(
            text: text,
            appliedEdits: edits,
            removedFillers: removedFillers,
            rulePathID: rulePathID
        )
    }

    // MARK: - Precompiled Regexes

    private static let fillerRegexes: [String: NSRegularExpression] = {
        let fillers = ["um", "uh", "you know", "i mean", "basically", "sort of", "kind of"]
        var dict: [String: NSRegularExpression] = [:]
        for filler in fillers {
            let escaped = NSRegularExpression.escapedPattern(for: filler)
            let pattern = "(?i)(?:\\s|^)\(escaped)(?=\\s|[,.!?]|$)"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                dict[filler] = regex
            }
        }
        return dict
    }()

    private static let likePatterns: [(regex: NSRegularExpression, replacement: String)] = {
        let specs: [(pattern: String, replacement: String)] = [
            ("(?i)(^|[.!?]\\s+)like,\\s+", "$1"),
            ("(?i),\\s*like,\\s*", ", ")
        ]
        return specs.compactMap { spec in
            guard let regex = try? NSRegularExpression(pattern: spec.pattern) else { return nil }
            return (regex, spec.replacement)
        }
    }()

    private static let whitespaceRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "\\s+")
    }()

    // MARK: - Filler Removal

    private func removeFillers(from text: String, policy: FillerPolicy) -> (text: String, removed: [String], edits: [TranscriptEdit]) {
        guard policy != .minimal else {
            return (text, [], [])
        }

        let balancedFillers = ["um", "uh", "you know"]
        let aggressiveFillers = balancedFillers + ["i mean", "basically", "sort of", "kind of"]
        let directFillers = policy == .balanced ? balancedFillers : aggressiveFillers

        var updated = text
        var removed: [String] = []
        var edits: [TranscriptEdit] = []

        for filler in directFillers {
            guard let regex = Self.fillerRegexes[filler] else { continue }

            let range = NSRange(updated.startIndex..., in: updated)
            let count = regex.numberOfMatches(in: updated, range: range)
            if count > 0 {
                updated = regex.stringByReplacingMatches(in: updated, range: range, withTemplate: " ")
                removed.append(contentsOf: Array(repeating: filler, count: count))
                edits.append(TranscriptEdit(kind: .fillerRemoval, from: filler, to: ""))
            }
        }

        let likeRemovals = removeInterjectionalLike(from: updated)
        updated = likeRemovals.text
        if likeRemovals.count > 0 {
            removed.append(contentsOf: Array(repeating: "like", count: likeRemovals.count))
            edits.append(TranscriptEdit(kind: .fillerRemoval, from: "like", to: ""))
        }

        updated = collapseWhitespace(updated)
        return (updated, removed, edits)
    }

    private func removeInterjectionalLike(from text: String) -> (text: String, count: Int) {
        var updated = text
        var removedCount = 0

        for item in Self.likePatterns {
            let range = NSRange(updated.startIndex..., in: updated)
            let count = item.regex.numberOfMatches(in: updated, range: range)
            if count > 0 {
                updated = item.regex.stringByReplacingMatches(in: updated, range: range, withTemplate: item.replacement)
                removedCount += count
            }
        }

        return (updated, removedCount)
    }

    // MARK: - Lexicon

    private func applyLexicon(text: String, lexicon: PersonalLexicon) -> (text: String, edits: [TranscriptEdit]) {
        var updated = text
        var edits: [TranscriptEdit] = []

        // Lexicon entries are already sorted longest-first by the PersonalLexicon invariant.
        for entry in lexicon.entries {
            let escaped = NSRegularExpression.escapedPattern(for: entry.term)
            let pattern = "\\b\(escaped)\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(updated.startIndex..., in: updated)
            let count = regex.numberOfMatches(in: updated, range: range)
            if count > 0 {
                let safeReplacement = NSRegularExpression.escapedTemplate(for: entry.preferred)
                updated = regex.stringByReplacingMatches(in: updated, range: range, withTemplate: safeReplacement)
                edits.append(TranscriptEdit(kind: .lexiconCorrection, from: entry.term, to: entry.preferred))
            }
        }

        return (updated, edits)
    }

    // MARK: - Structure

    private func applyStructure(text: String, mode: StructureMode) -> (text: String, edits: [TranscriptEdit]) {
        switch mode {
        case .natural, .command:
            return (text, [])
        case .paragraph:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (capitalizedSentence(trimmed), [TranscriptEdit(kind: .structureRewrite, from: "raw", to: "paragraph")])
        case .bullets:
            let clauses = splitIntoClauses(text)
            let bulletText = clauses.map { "- \($0)" }.joined(separator: "\n")
            return (bulletText, [TranscriptEdit(kind: .structureRewrite, from: "raw", to: "bullets")])
        case .email:
            let body = capitalizedSentence(text.trimmingCharacters(in: .whitespacesAndNewlines))
            let email = "Hi,\n\n\(body)\n\nThanks,"
            return (email, [TranscriptEdit(kind: .structureRewrite, from: "raw", to: "email")])
        }
    }

    private func splitIntoClauses(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",.;")
        let pieces = text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if pieces.isEmpty {
            return [capitalizedSentence(text)]
        }

        return pieces.map(capitalizedSentence)
    }

    private func capitalizedSentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    private func collapseWhitespace(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let collapsed = Self.whitespaceRegex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
