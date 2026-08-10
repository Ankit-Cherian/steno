import Foundation

enum FillerLiteralContext {
    static let clauseLeadTokens: Set<String> = [
        "i", "you", "we", "he", "she", "they", "it", "this", "that", "these", "those",
        "the", "a", "an", "there", "here", "please", "can", "could", "would", "should",
        "will", "may", "might", "must", "do", "does", "did", "is", "are", "was", "were",
        "have", "has", "had",
    ]

    private static let literalCueWords: Set<String> = [
        "called", "caption", "contains", "defines", "dictionary", "expects", "expression", "file",
        "game", "glossary", "identifier", "includes", "label", "list", "listed", "lists", "literal",
        "literally", "musical", "name", "named", "note", "phrase", "quote", "quoted", "records",
        "say", "said", "show", "song", "source", "spell", "string", "term", "text", "title",
        "token", "transcript", "type", "typed", "value", "variable", "word", "words", "write",
        "writes", "written", "wrote",
    ]

    private static let literalSuffixWords: Set<String> = [
        "exactly", "intentionally", "literal", "literally", "unchanged", "verbatim",
    ]

    private static let adjacentQuoteCharacters: Set<Character> = ["\"", "`", "“", "”", "‘", "’"]

    static func isProtected(prefix: String, suffix: String, matchedText: String) -> Bool {
        let linePrefix = currentLinePrefix(in: prefix)
        let lineSuffix = currentLineSuffix(in: suffix)
        let prefixWords = words(in: linePrefix)
        if prefixWords.suffix(8).contains(where: { literalCueWords.contains($0.lowercased()) }) {
            return true
        }

        let suffixWords = words(in: lineSuffix)
        let suffixLead = suffixWords.prefix(6).map { $0.lowercased() }
        if suffixLead.contains(where: literalSuffixWords.contains)
            || suffixLead.prefix(2).joined(separator: " ") == "as written"
            || suffixLead.prefix(2).joined(separator: " ") == "as text" {
            return true
        }

        if isInsideQuotedSpan(prefix: prefix) {
            return true
        }

        if let last = prefix.last(where: { $0.isWhitespace == false }), adjacentQuoteCharacters.contains(last) {
            return true
        }
        if let first = suffix.first(where: { $0.isWhitespace == false }), adjacentQuoteCharacters.contains(first) {
            return true
        }

        if linePrefix.trimmingCharacters(in: .whitespaces).isEmpty == false,
           matchedText.first?.isUppercase == true {
            return true
        }

        if linePrefix.trimmingCharacters(in: .whitespaces).isEmpty {
            if let first = suffixWords.first,
               let firstCharacter = first.first,
               firstCharacter.isUppercase,
               clauseLeadTokens.contains(first.lowercased()) == false {
                return true
            }
            if suffixWords.prefix(2).count == 2,
               suffixWords.prefix(2).allSatisfy({ $0.first?.isUppercase == true }) {
                return true
            }
        }

        return false
    }

    private static func words(in text: String) -> [String] {
        text.matches(of: /[A-Za-z0-9']+/).map { String($0.output) }
    }

    private static func currentLinePrefix(in text: String) -> String {
        guard let boundary = text.lastIndex(where: \.isNewline) else { return text }
        return String(text[text.index(after: boundary)...])
    }

    private static func currentLineSuffix(in text: String) -> String {
        guard let boundary = text.firstIndex(where: \.isNewline) else { return text }
        return String(text[..<boundary])
    }

    private static func isInsideQuotedSpan(prefix: String) -> Bool {
        let straightDoubleQuotes = prefix.filter { $0 == "\"" }.count
        let backticks = prefix.filter { $0 == "`" }.count
        if straightDoubleQuotes.isMultiple(of: 2) == false || backticks.isMultiple(of: 2) == false {
            return true
        }

        if let opening = prefix.lastIndex(of: "“") {
            return prefix.lastIndex(of: "”").map { $0 < opening } ?? true
        }
        if let opening = prefix.lastIndex(of: "‘") {
            return prefix.lastIndex(of: "’").map { $0 < opening } ?? true
        }
        return false
    }
}

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
            let pattern = "(?i)(?:[ \\t]|^)(\(escaped))(?=[ \\t]|[,.!?]|$)"
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
            let pattern = "(?i)(?:[ \\t]|^)(\(escaped))(?=[ \\t]|[,.!?]|$)"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                dict[filler] = regex
            }
        }
        return dict
    }()

    // MARK: - Filler Removal

    private func removeFillers(from text: String, policy: FillerPolicy) -> (text: String, removed: [String], edits: [TranscriptEdit]) {
        guard policy == .aggressive else {
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

        guard removed.isEmpty == false else {
            return (text, removed, edits)
        }

        return (updated, removed, edits)
    }

    private func applyFillerRemoval(
        _ filler: String,
        regex: NSRegularExpression,
        to text: inout String,
        removed: inout [String],
        edits: inout [TranscriptEdit]
    ) {
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        let acceptedFillerRanges = regex.matches(in: text, range: range).compactMap { match -> NSRange? in
            guard match.numberOfRanges > 1 else { return nil }
            let fillerRange = match.range(at: 1)
            guard fillerRange.location != NSNotFound else { return nil }

            let prefix = source.substring(with: NSRange(location: 0, length: fillerRange.location))
            let suffixStart = NSMaxRange(fillerRange)
            let suffix = source.substring(
                with: NSRange(location: suffixStart, length: source.length - suffixStart)
            )
            let matchedText = source.substring(with: fillerRange)
            guard FillerLiteralContext.isProtected(
                prefix: prefix,
                suffix: suffix,
                matchedText: matchedText
            ) == false else {
                return nil
            }
            return fillerRange
        }
        let acceptedEdits = coalescedFillerRanges(acceptedFillerRanges, in: source).map {
            localFillerRemovalEdit(for: $0, in: source)
        }
        guard acceptedEdits.isEmpty == false else { return }

        let mutable = NSMutableString(string: text)
        for (acceptedRange, replacement) in acceptedEdits.reversed() {
            mutable.replaceCharacters(in: acceptedRange, with: replacement)
        }
        text = String(mutable)
        removed.append(contentsOf: Array(repeating: filler, count: acceptedFillerRanges.count))
        edits.append(TranscriptEdit(kind: .fillerRemoval, from: filler, to: ""))
    }

    private func coalescedFillerRanges(
        _ ranges: [NSRange],
        in source: NSString
    ) -> [NSRange] {
        guard var current = ranges.first else { return [] }
        var result: [NSRange] = []

        for next in ranges.dropFirst() {
            let gapStart = NSMaxRange(current)
            let gapLength = next.location - gapStart
            let gapContainsOnlyLocalSeparators = gapLength >= 0
                && (gapStart..<(gapStart + gapLength)).allSatisfy { index in
                    let character = source.character(at: index)
                    return character == 0x2C || isHorizontalWhitespace(character)
                }

            if gapContainsOnlyLocalSeparators {
                current.length = NSMaxRange(next) - current.location
            } else {
                result.append(current)
                current = next
            }
        }

        result.append(current)
        return result
    }

    private func localFillerRemovalEdit(
        for fillerRange: NSRange,
        in source: NSString
    ) -> (NSRange, String) {
        var left = fillerRange.location - 1
        while left >= 0, isHorizontalWhitespace(source.character(at: left)) {
            left -= 1
        }

        var right = NSMaxRange(fillerRange)
        while right < source.length, isHorizontalWhitespace(source.character(at: right)) {
            right += 1
        }

        let leftIsComma = left >= 0 && source.character(at: left) == 0x2C
        let rightIsComma = right < source.length && source.character(at: right) == 0x2C
        let rightIsTerminalPunctuation = right < source.length
            && [0x2E, 0x21, 0x3F].contains(source.character(at: right))

        if leftIsComma, rightIsComma {
            var end = right + 1
            while end < source.length, isHorizontalWhitespace(source.character(at: end)) {
                end += 1
            }
            return (NSRange(location: left, length: end - left), " ")
        }

        if leftIsComma {
            let replacement = right >= source.length || rightIsTerminalPunctuation ? "" : " "
            return (NSRange(location: left, length: right - left), replacement)
        }

        if rightIsComma {
            var end = right + 1
            while end < source.length, isHorizontalWhitespace(source.character(at: end)) {
                end += 1
            }
            return (NSRange(location: fillerRange.location, length: end - fillerRange.location), "")
        }

        if right >= source.length || rightIsTerminalPunctuation {
            var start = fillerRange.location
            while start > 0, isHorizontalWhitespace(source.character(at: start - 1)) {
                start -= 1
            }
            return (NSRange(location: start, length: right - start), "")
        }

        return (
            NSRange(location: fillerRange.location, length: right - fillerRange.location),
            ""
        )
    }

    private func isHorizontalWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
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
                if LexiconSafety.shouldSkipLiteralReplacement(entry: entry, variant: variant) {
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
