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
        // Saved vocabulary is an explicit instruction, so it is applied deterministically before
        // any candidate is scored. Only edits Steno infers on its own are ranked.
        let vocabulary = LexiconMatcher(lexicon: lexicon).apply(to: raw.text)
        var corrected = raw
        corrected.text = vocabulary.text

        let generator = RuleBasedCleanupCandidateGenerator()
        let candidates = try await generator.generateCandidates(
            raw: corrected,
            profile: profile,
            lexicon: lexicon
        )

        // A spoken correction that passed the repair guards is also explicit: the ranker only
        // chooses how to resolve it, never whether to.
        let spokenCorrections = candidates.filter { candidate in
            candidate.appliedEdits.contains { $0.kind == .repairResolution }
        }
        let ranker = LocalCleanupRanker()
        let best = ranker.bestCandidate(
            raw: corrected,
            candidates: spokenCorrections.isEmpty ? candidates : spokenCorrections,
            profile: profile
        )

        return CleanTranscript(
            text: best.text,
            edits: vocabulary.edits + best.appliedEdits,
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

        let structureResult = applyStructure(
            text: text,
            mode: profile.structureMode,
            preservedSpellings: lexicon.entries.map(\.preferred)
        )
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

    // MARK: - Structure

    private func applyStructure(
        text: String,
        mode: StructureMode,
        preservedSpellings: [String]
    ) -> (text: String, edits: [TranscriptEdit]) {
        let capitalizedSentence = { (sentence: String) in
            self.capitalizedSentence(sentence, preservedSpellings: preservedSpellings)
        }

        switch mode {
        case .natural, .command:
            return (text, [])
        case .paragraph:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (capitalizedSentence(trimmed), [TranscriptEdit(kind: .structureRewrite, from: "raw", to: "paragraph")])
        case .bullets:
            let clauses = splitIntoClauses(text, capitalizedSentence: capitalizedSentence)
            let bulletText = clauses.map { "- \($0)" }.joined(separator: "\n")
            return (bulletText, [TranscriptEdit(kind: .structureRewrite, from: "raw", to: "bullets")])
        case .email:
            let body = capitalizedSentence(text.trimmingCharacters(in: .whitespacesAndNewlines))
            let email = "Hi,\n\n\(body)\n\nThanks,"
            return (email, [TranscriptEdit(kind: .structureRewrite, from: "raw", to: "email")])
        }
    }

    private static let clauseSeparators: Set<Character> = [",", ".", ";"]
    private static let abbreviationsWithFullStop: Set<String> = [
        "dr", "jr", "mr", "mrs", "ms", "prof", "sr", "st", "vs",
    ]

    /// Splits at a comma, full stop or semicolon only where it ends a clause: it must be followed by
    /// whitespace or the end of the text. Numbers (1.25, 1,250), email addresses and URLs have no
    /// space after their punctuation, so they stay whole. A full stop that ends an abbreviation
    /// (Dr., e.g., U.S.) does not split either.
    private func splitIntoClauses(_ text: String, capitalizedSentence: (String) -> String) -> [String] {
        let characters = Array(text)
        var pieces: [String] = []
        var pieceStart = 0

        for index in characters.indices where Self.clauseSeparators.contains(characters[index]) {
            let next = index + 1
            guard next == characters.count || characters[next].isWhitespace else { continue }
            if characters[index] == ".", endsWithAbbreviation(characters, before: index) { continue }
            pieces.append(String(characters[pieceStart..<index]))
            pieceStart = next
        }
        pieces.append(String(characters[pieceStart...]))

        let clauses = pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if clauses.isEmpty {
            return [capitalizedSentence(text)]
        }

        return clauses.map(capitalizedSentence)
    }

    /// Whether the word that ends at `index` (a full stop) is an abbreviation: a known title or
    /// short form, or a dotted form such as "e.g" or "U.S".
    private func endsWithAbbreviation(_ characters: [Character], before index: Int) -> Bool {
        var start = index
        while start > 0, characters[start - 1].isWhitespace == false {
            start -= 1
        }
        let word = String(characters[start..<index])
        guard word.isEmpty == false else { return false }
        if word.contains("."), word.allSatisfy({ $0.isLetter || $0 == "." }) {
            return true
        }
        return Self.abbreviationsWithFullStop.contains(word.lowercased())
    }

    /// Uppercases the first character unless the leading word is spelled deliberately: it has an
    /// interior capital (iPhone, eBay, macOS) or it is a saved preferred spelling (npm).
    private func capitalizedSentence(_ text: String, preservedSpellings: [String]) -> String {
        guard let first = text.first else { return text }
        let leadingWord = text.prefix { $0.isWhitespace == false }
        if leadingWord.dropFirst().contains(where: \.isUppercase) {
            return text
        }
        let startsWithPreservedSpelling = preservedSpellings.contains { spelling in
            let spelling = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
            guard spelling.first?.isLowercase == true, text.hasPrefix(spelling) else { return false }
            guard let next = text.dropFirst(spelling.count).first else { return true }
            return next.isLetter == false && next.isNumber == false
        }
        if startsWithPreservedSpelling {
            return text
        }
        return String(first).uppercased() + text.dropFirst()
    }
}
