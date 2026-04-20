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
            raw: raw,
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
        sourceText: String? = nil,
        seedEdits: [TranscriptEdit] = [],
        profile: StyleProfile,
        lexicon: PersonalLexicon,
        rulePathID: String
    ) -> CleanupCandidate {
        var text = sourceText ?? raw.text
        var edits: [TranscriptEdit] = seedEdits
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

    private static let unconditionalFillerRegexes: [String: NSRegularExpression] = {
        let fillers = ["um", "uh"]
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

    private static let aggressiveFillerRegexes: [String: NSRegularExpression] = {
        let fillers = ["i mean", "basically", "sort of", "kind of"]
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

    private static let contextualYouKnowRegex: NSRegularExpression = {
        let protected = "a|an|the|this|that|these|those|i|you|he|she|it|we|they|me|him|her|us|them|my|your|his|its|our|their|what|when|where|which|who|whom|whose|why|how|if"
        let pattern = "(?i)(?:\\s|^)you know(?=\\s(?!(?:\(protected))\\b)|[,.!?]|$)"
        return try! NSRegularExpression(pattern: pattern)
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

    private static let punctuationSpacingRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "\\s+([,.!?])")
    }()

    private static let leadingPunctuationRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^[,;:\s]+"#)
    }()

    private static let duplicateCommaRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #",\s*,+"#)
    }()

    // MARK: - Filler Removal

    private func removeFillers(from text: String, policy: FillerPolicy) -> (text: String, removed: [String], edits: [TranscriptEdit]) {
        guard policy != .minimal else {
            return (text, [], [])
        }

        let unconditionalFillers = ["um", "uh"]
        let aggressiveFillers = ["i mean", "basically", "sort of", "kind of"]

        var updated = text
        var removed: [String] = []
        var edits: [TranscriptEdit] = []

        for filler in unconditionalFillers {
            guard let regex = Self.unconditionalFillerRegexes[filler] else { continue }
            applyFillerRemoval(
                filler,
                regex: regex,
                to: &updated,
                removed: &removed,
                edits: &edits
            )
        }

        if policy == .aggressive {
            for filler in aggressiveFillers {
                guard let regex = Self.aggressiveFillerRegexes[filler] else { continue }
                applyFillerRemoval(
                    filler,
                    regex: regex,
                    to: &updated,
                    removed: &removed,
                    edits: &edits
                )
            }
        }

        applyFillerRemoval(
            "you know",
            regex: Self.contextualYouKnowRegex,
            to: &updated,
            removed: &removed,
            edits: &edits
        )

        let likeRemovals = removeInterjectionalLike(from: updated)
        updated = likeRemovals.text
        if likeRemovals.count > 0 {
            removed.append(contentsOf: Array(repeating: "like", count: likeRemovals.count))
            edits.append(TranscriptEdit(kind: .fillerRemoval, from: "like", to: ""))
        }

        updated = collapseWhitespace(updated)
        updated = cleanupFillerPunctuation(updated)
        return (updated, removed, edits)
    }

    private func applyFillerRemoval(
        _ filler: String,
        regex: NSRegularExpression,
        to text: inout String,
        removed: inout [String],
        edits: inout [TranscriptEdit]
    ) {
        let range = NSRange(text.startIndex..., in: text)
        let count = regex.numberOfMatches(in: text, range: range)
        if count > 0 {
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
            removed.append(contentsOf: Array(repeating: filler, count: count))
            edits.append(TranscriptEdit(kind: .fillerRemoval, from: filler, to: ""))
        }
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
            for variant in lexiconVariants(for: entry) {
                if variant.caseInsensitiveCompare(entry.preferred) == .orderedSame {
                    continue
                }
                let escaped = NSRegularExpression.escapedPattern(for: variant)
                let pattern = "\\b\(escaped)\\b"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(updated.startIndex..., in: updated)
                let count = regex.numberOfMatches(in: updated, range: range)
                if count > 0 {
                    let safeReplacement = NSRegularExpression.escapedTemplate(for: entry.preferred)
                    updated = regex.stringByReplacingMatches(in: updated, range: range, withTemplate: safeReplacement)
                    edits.append(TranscriptEdit(kind: .lexiconCorrection, from: variant, to: entry.preferred))
                }
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
        let punctuationRange = NSRange(collapsed.startIndex..., in: collapsed)
        let tightened = Self.punctuationSpacingRegex.stringByReplacingMatches(
            in: collapsed,
            range: punctuationRange,
            withTemplate: "$1"
        )
        return tightened.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanupFillerPunctuation(_ text: String) -> String {
        let fullRange = NSRange(text.startIndex..., in: text)
        let withoutLeading = Self.leadingPunctuationRegex.stringByReplacingMatches(
            in: text,
            range: fullRange,
            withTemplate: ""
        )
        let duplicateRange = NSRange(withoutLeading.startIndex..., in: withoutLeading)
        let withoutDuplicateCommas = Self.duplicateCommaRegex.stringByReplacingMatches(
            in: withoutLeading,
            range: duplicateRange,
            withTemplate: ", "
        )

        return withoutDuplicateCommas
            .replacingOccurrences(of: #",\s+(this|that|it|we|you|they|he|she|i)\b"#, with: " $1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func lexiconVariants(for entry: LexiconEntry) -> [String] {
        var variants = [entry.term]
        variants.append(contentsOf: entry.aliases)

        for source in [entry.term, entry.preferred] {
            let spaced = source
                .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
                .replacingOccurrences(of: #"[-_/]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if spaced.caseInsensitiveCompare(source) != .orderedSame {
                variants.append(spaced)
            }
        }

        var seen: Set<String> = []
        return variants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .filter { seen.insert($0.lowercased()).inserted }
    }
}
