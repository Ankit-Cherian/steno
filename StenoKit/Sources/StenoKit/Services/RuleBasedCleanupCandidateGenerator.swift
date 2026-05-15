import Foundation

enum RepairMarkerMatcher {
    struct Match {
        var marker: String
        var range: Range<String.Index>
    }

    private static let markerRegexes: [(marker: String, regex: NSRegularExpression)] = {
        let specs: [(String, String)] = [
            ("scratch that", #"\bscratch\s+that\b"#),
            ("delete that", #"\bdelete\s+that\b"#),
            ("erase that", #"\berase\s+that\b"#),
            ("never mind", #"\bnever\s+mind\b"#),
            ("i mean", #"\bi\s+mean\b"#),
            ("actually", #"\bactually\b"#),
            ("no", #"^\s*no\b"#),
        ]

        return specs.map { marker, pattern in
            (
                marker: marker,
                regex: try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            )
        }
    }()

    private static let blockedNoLeadTokens: Set<String> = [
        "i",
        "you",
        "we",
        "he",
        "she",
        "they",
        "it",
        "this",
        "that",
        "these",
        "those",
        "there",
        "here",
        "thanks",
        "thank",
        "maybe",
        "sorry",
    ]

    private static let declarativeSecondTokens: Set<String> = [
        "am",
        "is",
        "are",
        "was",
        "were",
        "be",
        "being",
        "been",
        "do",
        "does",
        "did",
        "have",
        "has",
        "had",
        "can",
        "could",
        "should",
        "would",
        "will",
        "may",
        "might",
        "must",
    ]

    static func firstMatch(in text: String) -> Match? {
        let fullRange = NSRange(text.startIndex..., in: text)

        for spec in Self.markerRegexes {
            guard let nsMatch = spec.regex.firstMatch(in: text, range: fullRange),
                  let range = Range(nsMatch.range, in: text)
            else {
                continue
            }

            let prefix = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

            if spec.marker == "no", shouldInterpretLeadingNoAsRepair(prefix: prefix, suffix: suffix) == false {
                continue
            }

            return Match(marker: spec.marker, range: range)
        }

        return nil
    }

    static func containsRepairMarker(in text: String) -> Bool {
        firstMatch(in: text) != nil
    }

    private static func shouldInterpretLeadingNoAsRepair(prefix: String, suffix: String) -> Bool {
        guard prefix.isEmpty else { return false }

        let tokens = normalizedWords(in: suffix)
        guard let firstToken = tokens.first else { return false }
        guard !blockedNoLeadTokens.contains(firstToken) else { return false }

        if tokens.count > 1, declarativeSecondTokens.contains(tokens[1]) {
            return false
        }

        return true
    }

    private static func normalizedWords(in text: String) -> [String] {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9'\s]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }
}

public struct RuleBasedCleanupCandidateGenerator: Sendable {
    private struct SeedVariant: Sendable {
        var text: String
        var edits: [TranscriptEdit]
        var rulePathID: String
    }

    private struct TokenSpan: Sendable {
        var text: String
        var range: Range<String.Index>
    }

    private static let wordRegex = try! NSRegularExpression(pattern: #"[A-Za-z0-9']+"#)

    public init() {}

    public func generateCandidates(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> [CleanupCandidate] {
        let engine = RuleBasedCleanupEngine()
        var candidates: [CleanupCandidate] = [
            CleanupCandidate(
                text: raw.text,
                appliedEdits: [],
                removedFillers: [],
                rulePathID: "raw-pass-through"
            )
        ]

        let seedVariants = buildSeedVariants(from: raw, lexicon: lexicon)
        let variants = profileVariants(from: profile)
        for seed in seedVariants {
            for (pathID, variantProfile) in variants {
                let candidate = engine.buildCandidate(
                    raw: raw,
                    sourceText: seed.text,
                    seedEdits: seed.edits,
                    profile: variantProfile,
                    lexicon: lexicon,
                    rulePathID: "\(seed.rulePathID)/\(pathID)"
                )
                candidates.append(candidate)
            }
        }

        return deduplicated(candidates)
    }

    private func profileVariants(from base: StyleProfile) -> [(String, StyleProfile)] {
        var variants: [(String, StyleProfile)] = []

        let minimal = StyleProfile(
            name: "\(base.name)-minimal",
            tone: base.tone,
            structureMode: base.structureMode,
            fillerPolicy: .minimal,
            commandPolicy: base.commandPolicy
        )
        variants.append(("profile-minimal", minimal))

        let balanced = StyleProfile(
            name: "\(base.name)-balanced",
            tone: base.tone,
            structureMode: base.structureMode,
            fillerPolicy: .balanced,
            commandPolicy: base.commandPolicy
        )
        variants.append(("profile-balanced", balanced))

        let aggressive = StyleProfile(
            name: "\(base.name)-aggressive",
            tone: base.tone,
            structureMode: base.structureMode,
            fillerPolicy: .aggressive,
            commandPolicy: base.commandPolicy
        )
        variants.append(("profile-aggressive", aggressive))

        return variants
    }

    private func deduplicated(_ candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        var seenTexts: Set<String> = []
        var result: [CleanupCandidate] = []
        result.reserveCapacity(candidates.count)

        for candidate in candidates {
            guard !seenTexts.contains(candidate.text) else { continue }
            seenTexts.insert(candidate.text)
            result.append(candidate)
        }

        return result
    }

    private func buildSeedVariants(
        from raw: RawTranscript,
        lexicon: PersonalLexicon
    ) -> [SeedVariant] {
        let base = SeedVariant(text: raw.text, edits: [], rulePathID: "literal")
        let repairs = repairVariants(from: raw.text)
        let spokenSymbols = spokenSymbolVariants(from: raw.text)
        var variants: [SeedVariant] = [base]
        variants.append(contentsOf: repairs)
        variants.append(contentsOf: spokenSymbols)

        var expanded: [SeedVariant] = variants
        for variant in variants {
            expanded.append(contentsOf: phoneticVariants(from: variant, lexicon: lexicon))
        }

        return expanded
    }

    private func repairVariants(from text: String) -> [SeedVariant] {
        guard let match = RepairMarkerMatcher.firstMatch(in: text) else { return [] }

        let prefix = String(text[..<match.range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(text[match.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suffix.isEmpty else { return [] }
        guard !looksLikeLiteralInstruction(prefix: prefix, suffix: suffix) else { return [] }

        let prefixTokens = tokenSpans(in: prefix)
        var candidates: [SeedVariant] = []

        if prefixTokens.isEmpty {
            candidates.append(
                SeedVariant(
                    text: normalizedRepairJoin(prefix: "", suffix: suffix),
                    edits: [.init(kind: .repairResolution, from: match.marker, to: suffix)],
                    rulePathID: "repair-\(sanitize(match.marker))-drop-prefix"
                )
            )
        } else {
            let maxReplacement = min(4, prefixTokens.count)
            for replacementCount in 1...maxReplacement {
                let replaceStart = prefixTokens[prefixTokens.count - replacementCount].range.lowerBound
                let rebuilt = normalizedRepairJoin(
                    prefix: String(prefix[..<replaceStart]),
                    suffix: suffix
                )
                candidates.append(
                    SeedVariant(
                        text: rebuilt,
                        edits: [.init(kind: .repairResolution, from: match.marker, to: suffix)],
                        rulePathID: "repair-\(sanitize(match.marker))-\(replacementCount)"
                    )
                )
            }
        }

        return candidates
    }

    private func spokenSymbolVariants(from text: String) -> [SeedVariant] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.hasPrefix("/") == false else { return [] }
        guard looksLikeLiteralSymbolInstruction(text) == false else { return [] }

        let spans = tokenSpans(in: text)
        guard !spans.isEmpty else { return [] }

        var pieces: [String] = []
        var edits: [TranscriptEdit] = []
        var index = 0
        var changed = false

        while index < spans.count {
            if let match = spokenSymbolMatch(in: spans, at: index) {
                let atStart = pieces.isEmpty
                guard shouldApplySpokenSymbolMatch(match, in: spans, at: index, atStart: atStart) else {
                    appendWord(spans[index].text, to: &pieces)
                    index += 1
                    continue
                }

                switch match.spacing {
                case .word:
                    appendWord(match.text, to: &pieces)
                case .punctuation:
                    appendPunctuation(match.text, to: &pieces)
                case .opening:
                    appendOpening(match.text, to: &pieces)
                case .closing:
                    appendClosing(match.text, to: &pieces)
                case .prefix:
                    guard atStart else {
                        appendWord(spans[index].text, to: &pieces)
                        index += 1
                        continue
                    }
                    appendPrefix(match.text, to: &pieces)
                }
                edits.append(.init(kind: match.kind, from: match.phrase, to: match.text))
                index += match.length
                changed = true
            } else {
                appendWord(spans[index].text, to: &pieces)
                index += 1
            }
        }

        guard changed else { return [] }
        let transformed = pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard transformed != trimmed else { return [] }
        guard isSafeSpokenSymbolCandidate(transformed) else { return [] }

        return [
            SeedVariant(
                text: transformed,
                edits: edits,
                rulePathID: "spoken-symbols"
            )
        ]
    }

    private enum SymbolSpacing {
        case word
        case punctuation
        case opening
        case closing
        case prefix
    }

    private struct SpokenSymbolMatch {
        var phrase: String
        var text: String
        var length: Int
        var spacing: SymbolSpacing
        var kind: TranscriptEdit.Kind
    }

    private func spokenSymbolMatch(in spans: [TokenSpan], at index: Int) -> SpokenSymbolMatch? {
        func matches(_ words: [String]) -> Bool {
            guard index + words.count <= spans.count else { return false }
            for offset in words.indices {
                guard normalize(spans[index + offset].text) == words[offset] else {
                    return false
                }
            }
            return true
        }

        let specs: [(words: [String], text: String, spacing: SymbolSpacing, kind: TranscriptEdit.Kind)] = [
            (["question", "mark"], "?", .punctuation, .punctuation),
            (["exclamation", "point"], "!", .punctuation, .punctuation),
            (["exclamation", "mark"], "!", .punctuation, .punctuation),
            (["open", "paren"], "(", .opening, .punctuation),
            (["open", "parenthesis"], "(", .opening, .punctuation),
            (["left", "paren"], "(", .opening, .punctuation),
            (["left", "parenthesis"], "(", .opening, .punctuation),
            (["close", "paren"], ")", .closing, .punctuation),
            (["close", "parenthesis"], ")", .closing, .punctuation),
            (["right", "paren"], ")", .closing, .punctuation),
            (["right", "parenthesis"], ")", .closing, .punctuation),
            (["forward", "slash"], "/", .prefix, .commandTransform),
            (["at", "sign"], "@", .prefix, .commandTransform),
            (["comma"], ",", .punctuation, .punctuation),
            (["period"], ".", .punctuation, .punctuation),
            (["backtick"], "`", .punctuation, .punctuation),
            (["slash"], "/", .prefix, .commandTransform),
        ]

        for spec in specs where matches(spec.words) {
            return SpokenSymbolMatch(
                phrase: spec.words.joined(separator: " "),
                text: spec.text,
                length: spec.words.count,
                spacing: spec.spacing,
                kind: spec.kind
            )
        }

        return nil
    }

    private func shouldApplySpokenSymbolMatch(
        _ match: SpokenSymbolMatch,
        in spans: [TokenSpan],
        at index: Int,
        atStart: Bool
    ) -> Bool {
        if match.spacing == .prefix {
            return atStart && isCommandPrefixContext(match, in: spans, at: index)
        }

        return isNounLikeSymbolReference(match, in: spans, at: index) == false
    }

    private func isNounLikeSymbolReference(
        _ match: SpokenSymbolMatch,
        in spans: [TokenSpan],
        at index: Int
    ) -> Bool {
        let previous = normalizedWord(in: spans, at: index - 1)
        if let previous, ["a", "an", "the"].contains(previous) {
            return true
        }

        let next = normalizedWord(in: spans, at: index + match.length)
        if let next, ["of", "key", "keys", "button", "word", "words", "phrase", "phrases", "character", "characters", "symbol", "symbols"].contains(next) {
            return true
        }

        return false
    }

    private func isCommandPrefixContext(
        _ match: SpokenSymbolMatch,
        in spans: [TokenSpan],
        at index: Int
    ) -> Bool {
        let remaining = spans.dropFirst(index + match.length).map { normalize($0.text) }
        guard remaining.isEmpty == false else { return false }
        guard remaining.count <= 3 else { return false }
        guard ["a", "an", "the"].contains(remaining[0]) == false else { return false }

        let proseSignals: Set<String> = [
            "am", "is", "are", "was", "were", "be", "being", "been",
            "mentioned", "discussed", "yesterday", "today", "meeting"
        ]
        return remaining.dropFirst().allSatisfy { proseSignals.contains($0) == false }
    }

    private func normalizedWord(in spans: [TokenSpan], at index: Int) -> String? {
        guard spans.indices.contains(index) else { return nil }
        return normalize(spans[index].text)
    }

    private func isSafeSpokenSymbolCandidate(_ text: String) -> Bool {
        guard tokenSpans(in: text).isEmpty == false else { return false }
        guard text.range(of: #"^[,.!?)]"#, options: .regularExpression) == nil else { return false }
        guard text.range(of: #"(,,|\.\.|\?\?|!!)"#, options: .regularExpression) == nil else { return false }
        guard text.hasSuffix(",") == false else { return false }
        guard text.hasSuffix("(") == false else { return false }
        guard text.filter({ $0 == "`" }).count.isMultiple(of: 2) else { return false }
        return hasBalancedParentheses(text)
    }

    private func hasBalancedParentheses(_ text: String) -> Bool {
        var depth = 0
        for character in text {
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }

    private func looksLikeLiteralSymbolInstruction(_ text: String) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }

        let words = tokenSpans(in: text).map { normalize($0.text) }
        if words.indices.contains(where: { index in
            index + 1 < words.count && words[index] == "spell" && words[index + 1] == "out"
        }) {
            return true
        }

        if words.contains(where: { $0 == "literal" || $0 == "literally" }) {
            let instructionCues = ["write", "type", "say", "spell"]
            if words.contains(where: { instructionCues.contains($0) }) {
                return true
            }
        }

        return false
    }

    private func appendWord(_ word: String, to pieces: inout [String]) {
        if pieces.isEmpty {
            pieces.append(word)
        } else if shouldAttachNextWord(after: pieces.last) {
            pieces.append(word)
        } else {
            pieces.append(" \(word)")
        }
    }

    private func shouldAttachNextWord(after piece: String?) -> Bool {
        guard let piece else { return false }
        return piece == "("
            || piece == "`"
            || piece == "/"
            || piece == "@"
    }

    private func appendPunctuation(_ mark: String, to pieces: inout [String]) {
        pieces.append(mark)
    }

    private func appendOpening(_ mark: String, to pieces: inout [String]) {
        if !pieces.isEmpty, shouldAttachNextWord(after: pieces.last) == false {
            pieces.append(" ")
        }
        pieces.append(mark)
    }

    private func appendClosing(_ mark: String, to pieces: inout [String]) {
        pieces.append(mark)
    }

    private func appendPrefix(_ mark: String, to pieces: inout [String]) {
        pieces.append(mark)
    }

    private func looksLikeLiteralInstruction(prefix: String, suffix: String) -> Bool {
        let normalizedPrefix = normalize(prefix)
        let normalizedSuffix = normalize(suffix)
        guard !normalizedPrefix.isEmpty else { return false }

        let literalCues = [
            "type",
            "write",
            "say",
            "spell",
            "literal",
            "literally"
        ]

        if let lastToken = normalizedPrefix.split(separator: " ").last,
           literalCues.contains(String(lastToken)) {
            return true
        }

        if normalizedSuffix == "literally" || normalizedSuffix == "literal" {
            return true
        }

        return false
    }

    private func phoneticVariants(from seed: SeedVariant, lexicon: PersonalLexicon) -> [SeedVariant] {
        let spans = tokenSpans(in: seed.text)
        guard spans.isEmpty == false else { return [] }

        var variants: [SeedVariant] = []

        for entry in lexicon.entries where isPhoneticCandidateEligible(entry) {
            let targetCodes = doubleMetaphoneCodes(entry.preferred)
            guard targetCodes.isEmpty == false else { continue }

            for windowSize in 1...min(2, spans.count) {
                for start in 0...(spans.count - windowSize) {
                    let end = start + windowSize - 1
                    let original = spans[start...end].map(\.text).joined(separator: " ")
                    let joined = spans[start...end].map(\.text).joined()
                    let normalizedOriginal = normalize(joined)
                    let targetNormalized = normalize(entry.preferred)
                    let sourceCodes = doubleMetaphoneCodes(joined)

                    guard normalizedOriginal != targetNormalized else { continue }
                    guard sourceCodes.isDisjoint(with: targetCodes) == false else { continue }

                    let candidate = String(seed.text[..<spans[start].range.lowerBound])
                        + entry.preferred
                        + String(seed.text[spans[end].range.upperBound...])
                    variants.append(
                        SeedVariant(
                            text: collapseCandidateWhitespace(candidate),
                            edits: seed.edits + [.init(kind: .lexiconCorrection, from: original, to: entry.preferred)],
                            rulePathID: "\(seed.rulePathID)/phonetic-\(sanitize(entry.preferred))-\(start)"
                        )
                    )
                }
            }
        }

        return variants
    }

    private func tokenSpans(in text: String) -> [TokenSpan] {
        let range = NSRange(text.startIndex..., in: text)
        return Self.wordRegex.matches(in: text, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: text) else { return nil }
            return TokenSpan(text: String(text[tokenRange]), range: tokenRange)
        }
    }

    private func collapseCandidateWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedRepairJoin(prefix: String, suffix: String) -> String {
        let trimmedPrefix = prefix.replacingOccurrences(
            of: #"[,.!?\-:;]\s*$"#,
            with: "",
            options: .regularExpression
        )
        let trimmedSuffix = suffix.replacingOccurrences(
            of: #"^[\s,.!?\-:;]+"#,
            with: "",
            options: .regularExpression
        )

        return collapseCandidateWhitespace(
            [trimmedPrefix, trimmedSuffix]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        )
    }

    private func isPhoneticCandidateEligible(_ entry: LexiconEntry) -> Bool {
        guard entry.phoneticRecovery == .properNounEnglish else {
            return false
        }

        let preferred = entry.preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preferred.isEmpty == false else {
            return false
        }

        let isShortAllCapsAcronym = preferred == preferred.uppercased() && preferred.count <= 4
        return isShortAllCapsAcronym == false
    }

    private func doubleMetaphoneCodes(_ text: String) -> Set<String> {
        let normalized = normalize(text).uppercased()
        guard normalized.isEmpty == false else { return [] }

        let characters = Array(normalized)
        var primary = ""
        var alternate = ""
        var index = 0

        func char(at offset: Int) -> Character? {
            let target = index + offset
            guard characters.indices.contains(target) else { return nil }
            return characters[target]
        }

        func slice(_ start: Int, _ length: Int) -> String {
            let lower = index + start
            let upper = min(lower + length, characters.count)
            guard lower < characters.count, lower >= 0, lower < upper else { return "" }
            return String(characters[lower..<upper])
        }

        func append(_ value: String, alternate alt: String? = nil) {
            primary.append(value)
            alternate.append(alt ?? value)
        }

        if normalized.hasPrefix("GN") || normalized.hasPrefix("KN") || normalized.hasPrefix("PN") || normalized.hasPrefix("WR") {
            index = 1
        } else if normalized.hasPrefix("X") {
            append("S")
            index = 1
        }

        while index < characters.count {
            let current = characters[index]

            switch current {
            case "A", "E", "I", "O", "U":
                if index == 0 { append("A") }
                index += 1
            case "B":
                append("P")
                index += char(at: 1) == "B" ? 2 : 1
            case "C":
                if slice(0, 2) == "CH" {
                    append("X", alternate: "K")
                    index += 2
                } else if slice(0, 3) == "CIA" {
                    append("X")
                    index += 3
                } else if let next = char(at: 1), ["E", "I", "Y"].contains(next) {
                    append("S")
                    index += 2
                } else {
                    append("K")
                    index += char(at: 1) == "C" ? 2 : 1
                }
            case "D":
                if slice(0, 3) == "DGE" || slice(0, 3) == "DGI" || slice(0, 3) == "DGY" {
                    append("J")
                    index += 3
                } else {
                    append("T")
                    index += char(at: 1) == "D" ? 2 : 1
                }
            case "F":
                append("F")
                index += char(at: 1) == "F" ? 2 : 1
            case "G":
                if slice(0, 2) == "GH" {
                    append("K")
                    index += 2
                } else if let next = char(at: 1), ["E", "I", "Y"].contains(next) {
                    append("J", alternate: "K")
                    index += 2
                } else {
                    append("K")
                    index += char(at: 1) == "G" ? 2 : 1
                }
            case "H":
                let previous = index > 0 ? characters[index - 1] : nil
                let next = char(at: 1)
                let previousIsVowel = previous.map { "AEIOU".contains($0) } ?? false
                let nextIsVowel = next.map { "AEIOU".contains($0) } ?? false
                if nextIsVowel && (index == 0 || previousIsVowel == false) {
                    append("H")
                }
                index += 1
            case "J":
                append("J")
                index += char(at: 1) == "J" ? 2 : 1
            case "K", "Q":
                append("K")
                index += char(at: 1) == current ? 2 : 1
            case "L":
                append("L")
                index += char(at: 1) == "L" ? 2 : 1
            case "M":
                append("M")
                index += char(at: 1) == "M" ? 2 : 1
            case "N":
                append("N")
                index += char(at: 1) == "N" ? 2 : 1
            case "P":
                if char(at: 1) == "H" {
                    append("F")
                    index += 2
                } else {
                    append("P")
                    index += char(at: 1) == "P" ? 2 : 1
                }
            case "R":
                append("R")
                index += char(at: 1) == "R" ? 2 : 1
            case "S":
                if slice(0, 2) == "SH" || slice(0, 3) == "SIO" || slice(0, 3) == "SIA" {
                    append("X")
                    index += 2
                } else {
                    append("S")
                    index += char(at: 1) == "S" ? 2 : 1
                }
            case "T":
                if slice(0, 3) == "TIA" || slice(0, 3) == "TIO" {
                    append("X")
                    index += 3
                } else if slice(0, 2) == "TH" {
                    append("0", alternate: "T")
                    index += 2
                } else {
                    append("T")
                    index += char(at: 1) == "T" ? 2 : 1
                }
            case "V":
                append("F")
                index += char(at: 1) == "V" ? 2 : 1
            case "W", "Y":
                if let next = char(at: 1), "AEIOU".contains(next) {
                    append(String(current))
                }
                index += 1
            case "X":
                append("KS")
                index += 1
            case "Z":
                append("S")
                index += char(at: 1) == "Z" ? 2 : 1
            default:
                index += 1
            }
        }

        return Set([primary, alternate].filter { !$0.isEmpty })
    }

    private func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
    }

    private func sanitize(_ text: String) -> String {
        normalize(text)
    }
}
