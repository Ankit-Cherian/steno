import Foundation

/// Decides whether a filler match is a literal use of the word that must be kept. It reads only a
/// few words on either side of the match within its line, and quote state is computed once per
/// text, so checking every match in a long dictation stays linear.
struct FillerLiteralContext {
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

    /// " ` “ ” ‘ ’
    private static let adjacentQuoteUnits: Set<unichar> = [0x22, 0x60, 0x201C, 0x201D, 0x2018, 0x2019]
    private static let newlineUnits: Set<unichar> = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]

    private let units: [unichar]
    /// `insideQuoteBefore[i]`: the text before UTF-16 offset `i` leaves a quoted span open.
    private let insideQuoteBefore: [Bool]

    init(text: String) {
        let units = Array(text.utf16)
        var insideQuoteBefore = [Bool](repeating: false, count: units.count + 1)
        var openStraightDouble = false
        var openBacktick = false
        var lastOpenCurlyDouble = -1
        var lastCloseCurlyDouble = -1
        var lastOpenCurlySingle = -1
        var lastCloseCurlySingle = -1

        for (index, unit) in units.enumerated() {
            switch unit {
            case 0x22: openStraightDouble.toggle()
            case 0x60: openBacktick.toggle()
            case 0x201C: lastOpenCurlyDouble = index
            case 0x201D: lastCloseCurlyDouble = index
            case 0x2018: lastOpenCurlySingle = index
            case 0x2019: lastCloseCurlySingle = index
            default: break
            }

            let inside: Bool
            if openStraightDouble || openBacktick {
                inside = true
            } else if lastOpenCurlyDouble >= 0 {
                inside = lastCloseCurlyDouble < lastOpenCurlyDouble
            } else if lastOpenCurlySingle >= 0 {
                inside = lastCloseCurlySingle < lastOpenCurlySingle
            } else {
                inside = false
            }
            insideQuoteBefore[index + 1] = inside
        }

        self.units = units
        self.insideQuoteBefore = insideQuoteBefore
    }

    /// With `sentenceStartIsLineStart`, a match that begins a sentence ("wire. Um, I tried") is
    /// judged like one that begins a line: its capital is the sentence's, not a sign of a name, and
    /// words in the previous sentence are not literal cues for it.
    func isProtected(_ range: NSRange, matchedText: String, sentenceStartIsLineStart: Bool = false) -> Bool {
        let start = range.location
        let end = NSMaxRange(range)
        let startsSentence = sentenceStartIsLineStart && startsSentence(at: start)

        if startsSentence == false,
           wordsBefore(start, limit: 8).contains(where: { Self.literalCueWords.contains($0.lowercased()) }) {
            return true
        }

        let suffixWords = wordsAfter(end, limit: 6)
        let suffixLead = suffixWords.map { $0.lowercased() }
        if suffixLead.contains(where: Self.literalSuffixWords.contains)
            || suffixLead.prefix(2).joined(separator: " ") == "as written"
            || suffixLead.prefix(2).joined(separator: " ") == "as text" {
            return true
        }

        if insideQuoteBefore[start] {
            return true
        }

        if let last = lastNonWhitespaceUnit(before: start), Self.adjacentQuoteUnits.contains(last) {
            return true
        }
        if let first = firstNonWhitespaceUnit(from: end), Self.adjacentQuoteUnits.contains(first) {
            return true
        }

        let lineStartsHere = isLinePrefixBlank(before: start) || startsSentence
        if lineStartsHere == false, matchedText.first?.isUppercase == true {
            return true
        }

        // A filler that is a sentence of its own ("Uh. Thanks.") is followed by the next
        // sentence, whose capital says nothing about the filler.
        let endsOwnSentence = firstNonWhitespaceUnit(from: end).map { $0 == 0x2E || $0 == 0x21 || $0 == 0x3F } ?? false
        if lineStartsHere, endsOwnSentence == false {
            if let first = suffixWords.first,
               let firstCharacter = first.first,
               firstCharacter.isUppercase,
               Self.clauseLeadTokens.contains(first.lowercased()) == false {
                return true
            }
            if suffixWords.prefix(2).count == 2,
               suffixWords.prefix(2).allSatisfy({ $0.first?.isUppercase == true }) {
                return true
            }
        }

        return false
    }

    /// ASCII letters, digits and apostrophes, the word characters of the literal-cue check.
    private static func isWordUnit(_ unit: unichar) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
            || (unit >= 0x30 && unit <= 0x39) || unit == 0x27
    }

    private static func isWhitespaceUnit(_ unit: unichar) -> Bool {
        Unicode.Scalar(unit)?.properties.isWhitespace == true
    }

    /// Up to `limit` words that end before `offset` on the same line, in text order.
    private func wordsBefore(_ offset: Int, limit: Int) -> [String] {
        var words: [String] = []
        var index = offset - 1
        while index >= 0, words.count < limit, Self.newlineUnits.contains(units[index]) == false {
            guard Self.isWordUnit(units[index]) else {
                index -= 1
                continue
            }
            let wordEnd = index + 1
            while index >= 0, Self.isWordUnit(units[index]) {
                index -= 1
            }
            words.append(String(decoding: units[(index + 1)..<wordEnd], as: UTF16.self))
        }
        return words.reversed()
    }

    /// Up to `limit` words that start at or after `offset` on the same line.
    private func wordsAfter(_ offset: Int, limit: Int) -> [String] {
        var words: [String] = []
        var index = offset
        while index < units.count, words.count < limit, Self.newlineUnits.contains(units[index]) == false {
            guard Self.isWordUnit(units[index]) else {
                index += 1
                continue
            }
            let wordStart = index
            while index < units.count, Self.isWordUnit(units[index]) {
                index += 1
            }
            words.append(String(decoding: units[wordStart..<index], as: UTF16.self))
        }
        return words
    }

    private func lastNonWhitespaceUnit(before offset: Int) -> unichar? {
        var index = offset - 1
        while index >= 0, Self.isWhitespaceUnit(units[index]) {
            index -= 1
        }
        return index >= 0 ? units[index] : nil
    }

    private func firstNonWhitespaceUnit(from offset: Int) -> unichar? {
        var index = offset
        while index < units.count, Self.isWhitespaceUnit(units[index]) {
            index += 1
        }
        return index < units.count ? units[index] : nil
    }

    /// The word directly before `offset`, separated from it only by spaces or tabs.
    func adjacentWord(before offset: Int) -> String? {
        var index = offset - 1
        while index >= 0, units[index] == 0x20 || units[index] == 0x09 {
            index -= 1
        }
        guard index >= 0, Self.isWordUnit(units[index]) else { return nil }
        return wordsBefore(index + 1, limit: 1).first
    }

    /// Whether a full stop, question mark or exclamation mark ends the text before `offset`.
    private func startsSentence(at offset: Int) -> Bool {
        guard let last = lastNonWhitespaceUnit(before: offset) else { return false }
        return last == 0x2E || last == 0x21 || last == 0x3F
    }

    /// Whether only spaces or tabs separate `offset` from the start of its line.
    private func isLinePrefixBlank(before offset: Int) -> Bool {
        var index = offset - 1
        while index >= 0 {
            let unit = units[index]
            if Self.newlineUnits.contains(unit) { return true }
            guard let scalar = Unicode.Scalar(unit), CharacterSet.whitespaces.contains(scalar) else {
                return false
            }
            index -= 1
        }
        return true
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

        // Under Aggressive, a dictation made only of fillers has nothing left to insert, however
        // short it is. Returning the empty text lets the session treat it as no speech.
        if let fillerOnly = candidates.first(where: { candidate in
            candidate.removedFillers.isEmpty == false
                && candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return CleanTranscript(
                text: "",
                edits: vocabulary.edits + fillerOnly.appliedEdits,
                removedFillers: fillerOnly.removedFillers,
                uncertaintyFlags: []
            )
        }

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

    /// "kind of" and "sort of" are hedges in "it's kind of unstable" but mean "type of" in "what
    /// kind of car". After a determiner they introduce a noun and are kept.
    private static let typeOfFillers: Set<String> = ["kind of", "sort of"]
    private static let typeOfDeterminers: Set<String> = [
        "a", "an", "any", "certain", "different", "each", "every", "no", "one", "other",
        "particular", "same", "some", "that", "the", "these", "this", "those", "what", "which",
    ]

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
                sentenceStartIsLineStart: true,
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
                // "I" is always written with a capital, and "I mean" opening a sentence often
                // carries meaning ("I mean what I say"), so it keeps the stricter rule.
                sentenceStartIsLineStart: filler != "i mean",
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
        sentenceStartIsLineStart: Bool,
        to text: inout String,
        removed: inout [String],
        edits: inout [TranscriptEdit]
    ) {
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        let context = FillerLiteralContext(text: text)
        let acceptedFillerRanges = regex.matches(in: text, range: range).compactMap { match -> NSRange? in
            guard match.numberOfRanges > 1 else { return nil }
            let fillerRange = match.range(at: 1)
            guard fillerRange.location != NSNotFound else { return nil }
            guard context.isProtected(
                fillerRange,
                matchedText: source.substring(with: fillerRange),
                sentenceStartIsLineStart: sentenceStartIsLineStart
            ) == false else {
                return nil
            }
            if Self.typeOfFillers.contains(filler),
               let previous = context.adjacentWord(before: fillerRange.location),
               Self.typeOfDeterminers.contains(previous.lowercased()) {
                return nil
            }
            return fillerRange
        }
        let acceptedEdits = coalescedFillerRanges(acceptedFillerRanges, in: source).map {
            localFillerRemovalEdit(for: $0, in: source)
        }
        guard acceptedEdits.isEmpty == false else { return }

        // Build the result front to back so the cost stays linear in the length of the text.
        let rebuilt = NSMutableString(capacity: source.length)
        var copiedUpTo = 0
        for (acceptedRange, replacement) in acceptedEdits where acceptedRange.location >= copiedUpTo {
            rebuilt.append(source.substring(with: NSRange(location: copiedUpTo, length: acceptedRange.location - copiedUpTo)))
            rebuilt.append(replacement)
            copiedUpTo = NSMaxRange(acceptedRange)
        }
        rebuilt.append(source.substring(from: copiedUpTo))
        text = String(rebuilt)
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

    /// Removes a filler run with the spacing and punctuation around it. At the start of a sentence,
    /// a run followed by the sentence's closing punctuation ("Um, uh.") is removed together with
    /// that punctuation, and the capital the filler carried moves to the word that now opens the
    /// sentence ("Um, yeah." becomes "Yeah.").
    private func localFillerRemovalEdit(
        for fillerRange: NSRange,
        in source: NSString
    ) -> (NSRange, String) {
        var left = fillerRange.location - 1
        while left >= 0, isHorizontalWhitespace(source.character(at: left)) {
            left -= 1
        }
        let startsSentence = left < 0 || [0x2E, 0x21, 0x3F, 0x0A, 0x0D].contains(source.character(at: left))
        guard startsSentence else {
            return fillerRemovalEdit(for: fillerRange, in: source)
        }

        var right = NSMaxRange(fillerRange)
        while right < source.length, isHorizontalWhitespace(source.character(at: right)) {
            right += 1
        }

        var edit: (range: NSRange, replacement: String)
        if right < source.length, isTerminalPunctuation(source.character(at: right)) {
            var end = right
            while end < source.length, isTerminalPunctuation(source.character(at: end)) {
                end += 1
            }
            while end < source.length, isHorizontalWhitespace(source.character(at: end)) {
                end += 1
            }
            var start = fillerRange.location
            if end >= source.length {
                while start > 0, isHorizontalWhitespace(source.character(at: start - 1)) {
                    start -= 1
                }
            }
            edit = (NSRange(location: start, length: end - start), "")
        } else {
            edit = fillerRemovalEdit(for: fillerRange, in: source)
        }

        guard edit.replacement.isEmpty,
              source.substring(with: fillerRange).first?.isUppercase == true
        else {
            return edit
        }
        var wordEnd = NSMaxRange(edit.range)
        while wordEnd < source.length,
              let scalar = Unicode.Scalar(source.character(at: wordEnd)),
              CharacterSet.letters.contains(scalar) {
            wordEnd += 1
        }
        let nextWord = source.substring(with: NSRange(location: NSMaxRange(edit.range), length: wordEnd - NSMaxRange(edit.range)))
        guard let initial = nextWord.first,
              initial.isLowercase,
              nextWord.dropFirst().contains(where: \.isUppercase) == false
        else {
            return edit
        }
        edit.range.length += String(initial).utf16.count
        edit.replacement = String(initial).uppercased()
        return edit
    }

    private func isTerminalPunctuation(_ character: unichar) -> Bool {
        character == 0x2E || character == 0x21 || character == 0x3F
    }

    private func fillerRemovalEdit(
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

        switch mode.effective {
        case .natural, .command:
            return (text, [])
        case .paragraph, .email:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (capitalizedSentence(trimmed), [TranscriptEdit(kind: .structureRewrite, from: "raw", to: "paragraph")])
        case .bullets:
            let clauses = splitIntoClauses(text, capitalizedSentence: capitalizedSentence)
            let bulletText = clauses.map { "- \($0)" }.joined(separator: "\n")
            return (bulletText, [TranscriptEdit(kind: .structureRewrite, from: "raw", to: "bullets")])
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
