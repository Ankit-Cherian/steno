import Foundation

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
        var variants: [SeedVariant] = [base]
        variants.append(contentsOf: repairs)

        var expanded: [SeedVariant] = variants
        for variant in variants {
            expanded.append(contentsOf: phoneticVariants(from: variant, lexicon: lexicon))
        }

        return expanded
    }

    private func repairVariants(from text: String) -> [SeedVariant] {
        let markers = [
            "scratch that",
            "delete that",
            "erase that",
            "never mind",
            "i mean",
            "actually",
            "no,"
        ]

        for marker in markers {
            guard let range = text.range(of: marker, options: [.caseInsensitive]) else { continue }
            let prefix = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !suffix.isEmpty else { continue }
            guard !looksLikeLiteralInstruction(prefix: prefix, suffix: suffix) else { continue }

            let prefixTokens = tokenSpans(in: prefix)
            var candidates: [SeedVariant] = []

            if prefixTokens.isEmpty {
                candidates.append(
                    SeedVariant(
                        text: normalizedRepairJoin(prefix: "", suffix: suffix),
                        edits: [.init(kind: .repairResolution, from: marker, to: suffix)],
                        rulePathID: "repair-\(sanitize(marker))-drop-prefix"
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
                            edits: [.init(kind: .repairResolution, from: marker, to: suffix)],
                            rulePathID: "repair-\(sanitize(marker))-\(replacementCount)"
                        )
                    )
                }
            }

            return candidates
        }

        return []
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
            of: #"[,\-:;]\s*$"#,
            with: "",
            options: .regularExpression
        )
        let trimmedSuffix = suffix.replacingOccurrences(
            of: #"^[,\-:;]\s*"#,
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
