import Foundation

public struct LocalCleanupRanker: Sendable {
    public init() {}

    private static let removableYouKnowRegex: NSRegularExpression = {
        let protected = "a|an|the|this|that|these|those|i|you|he|she|it|we|they|me|him|her|us|them|my|your|his|its|our|their|what|when|where|which|who|whom|whose|why|how|if"
        let pattern = "(?i)(?:\\s|^)you know(?=\\s(?!(?:\(protected))\\b)|[,.!?]|$)"
        return try! NSRegularExpression(pattern: pattern)
    }()

    public func bestCandidate(
        raw: RawTranscript,
        candidates: [CleanupCandidate],
        profile: StyleProfile
    ) -> CleanupCandidate {
        guard let first = candidates.first else {
            return CleanupCandidate(
                text: raw.text,
                appliedEdits: [],
                removedFillers: [],
                rulePathID: "raw-pass-through"
            )
        }

        var best = first
        var bestScore = scoreCandidate(raw: raw, candidate: first, profile: profile)

        for candidate in candidates.dropFirst() {
            let score = scoreCandidate(raw: raw, candidate: candidate, profile: profile)
            if score.totalScore > bestScore.totalScore + 1e-12 {
                best = candidate
                bestScore = score
                continue
            }

            if abs(score.totalScore - bestScore.totalScore) <= 1e-12,
               candidate.rulePathID < best.rulePathID {
                best = candidate
                bestScore = score
            }
        }

        return best
    }

    public func bestCandidate(
        rawText: String,
        candidates: [CleanupCandidate],
        profile: StyleProfile
    ) -> CleanupCandidate {
        bestCandidate(
            raw: RawTranscript(text: rawText),
            candidates: candidates,
            profile: profile
        )
    }

    public func scoreCandidate(
        raw: RawTranscript,
        candidate: CleanupCandidate,
        profile: StyleProfile
    ) -> CleanupRankingScore {
        let semantic = semanticPreservationScore(rawText: raw.text, candidate: candidate)
        let fluency = fluencyScore(text: candidate.text)
        let editPenalty = editDistancePenalty(rawText: raw.text, candidateText: candidate.text)
        let commandPenalty = commandSafetyPenalty(
            rawText: raw.text,
            candidateText: candidate.text,
            profile: profile
        )
        let confidenceAdjustment = confidenceAdjustment(raw: raw, candidate: candidate)
        let phoneticPenalty = phoneticPenalty(candidate: candidate)

        let total = (semantic * 0.65)
            + (fluency * 0.25)
            + confidenceAdjustment
            - (editPenalty * 0.10)
            - (commandPenalty * 1.0)
            - phoneticPenalty

        return CleanupRankingScore(
            semanticPreservationScore: semantic,
            fluencyScore: fluency,
            editDistancePenalty: editPenalty,
            commandSafetyPenalty: commandPenalty,
            totalScore: total
        )
    }

    public func scoreCandidate(
        rawText: String,
        candidate: CleanupCandidate,
        profile: StyleProfile
    ) -> CleanupRankingScore {
        scoreCandidate(
            raw: RawTranscript(text: rawText),
            candidate: candidate,
            profile: profile
        )
    }

    private func semanticPreservationScore(rawText: String, candidate: CleanupCandidate) -> Double {
        let rawNormalized = normalize(rawText)
        let candidateNormalized = normalize(candidate.text)

        var score = 1.0
        let protectedLikePhrases = [
            "seemed like",
            "seems like",
            "looks like",
            "looked like",
            "feel like",
            "felt like",
            "would like",
            "didn't like",
            "didnt like",
            "like that",
            "like this",
            "like a",
            "like an",
            "like to",
        ]

        for phrase in protectedLikePhrases {
            if rawNormalized.contains(phrase), !candidateNormalized.contains(phrase) {
                score -= 0.25
            }
        }

        let riskyLikeRemovals = candidate.removedFillers.filter { $0.caseInsensitiveCompare("like") == .orderedSame }.count
        if riskyLikeRemovals > 0 {
            score -= min(0.3, Double(riskyLikeRemovals) * 0.15)
        }

        let rawWords = tokenizeWords(rawNormalized)
        let candidateWords = tokenizeWords(candidateNormalized)
        if rawWords.count > candidateWords.count, !rawWords.isEmpty {
            let dropped = rawWords.count - candidateWords.count
            let accountedFillerDrops = min(dropped, candidate.removedFillers.count)
            let nonFillerDrops = dropped - accountedFillerDrops
            if nonFillerDrops > 0 {
                score -= min(0.4, Double(nonFillerDrops) / Double(rawWords.count))
            }
        }

        let safeRemoved = candidate.removedFillers.filter { isUnambiguousFiller($0) }.count
        if safeRemoved > 0 {
            score += min(0.2, Double(safeRemoved) * 0.1)
        }

        let repairEdits = candidate.appliedEdits.filter { $0.kind == .repairResolution }.count
        if repairEdits > 0 {
            score += min(0.35, Double(repairEdits) * 0.2)
            if repairMarkersPresent(in: rawText) && !repairMarkersPresent(in: candidate.text) {
                score += 0.15
            }
        } else if repairMarkersPresent(in: rawText) && repairMarkersPresent(in: candidate.text) {
            score -= 0.2
        }

        if isContextualYouKnowRemoved(rawText: rawText, candidate: candidate) {
            score += 0.15
        }

        let lexiconEdits = candidate.appliedEdits.filter { $0.kind == .lexiconCorrection }.count
        if lexiconEdits > 0 {
            score += min(0.2, Double(lexiconEdits) * 0.08)
        }

        if isInterjectionalLikeRemoved(rawText: rawText, candidate: candidate) {
            score += 0.15
        }

        return clamp(score, maxValue: 1.2)
    }

    private func fluencyScore(text: String) -> Double {
        var score = 1.0

        if text.range(of: #"^[\s]*[,.!?;:]"#, options: .regularExpression) != nil {
            score -= 0.25
        }
        if text.range(of: #"(?i)(^|[.!?]\s+)like,\s+|,\s*like,\s*"#, options: .regularExpression) != nil {
            score -= 0.2
        }
        if text.contains("  ") {
            score -= 0.2
        }
        if text.contains(",.") || text.contains("..") {
            score -= 0.2
        }

        return clamp(score)
    }

    private func editDistancePenalty(rawText: String, candidateText: String) -> Double {
        let rawWords = tokenizeWords(normalize(rawText))
        let candidateWords = tokenizeWords(normalize(candidateText))

        if rawWords == candidateWords { return 0 }
        if rawWords.isEmpty { return candidateWords.isEmpty ? 0 : 1 }

        let distance = levenshteinDistance(rawWords, candidateWords)
        return clamp(Double(distance) / Double(max(rawWords.count, 1)))
    }

    private func commandSafetyPenalty(
        rawText: String,
        candidateText: String,
        profile: StyleProfile
    ) -> Double {
        guard profile.commandPolicy == .passthrough else { return 0 }
        let rawTrimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawTrimmed.hasPrefix("/") else { return 0 }
        let candidateTrimmed = candidateText.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidateTrimmed == rawTrimmed ? 0 : 1
    }

    private func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9'\s]+"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tokenizeWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func clamp(_ value: Double) -> Double {
        clamp(value, maxValue: 1)
    }

    private func clamp(_ value: Double, maxValue: Double) -> Double {
        min(max(value, 0), maxValue)
    }

    private func isUnambiguousFiller(_ filler: String) -> Bool {
        let normalized = filler.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let known: Set<String> = [
            "um",
            "uh",
            "you know",
            "i mean",
            "basically",
            "sort of",
            "kind of",
        ]
        return known.contains(normalized)
    }

    private func isInterjectionalLikeRemoved(rawText: String, candidate: CleanupCandidate) -> Bool {
        guard candidate.removedFillers.contains(where: { $0.caseInsensitiveCompare("like") == .orderedSame }) else {
            return false
        }

        let rawHasInterjection = rawText.range(
            of: #"(?i)(^|[.!?]\s+)like,\s+|,\s*like,\s*"#,
            options: .regularExpression
        ) != nil
        guard rawHasInterjection else { return false }

        let candidateStillHasInterjection = candidate.text.range(
            of: #"(?i)(^|[.!?]\s+)like,\s+|,\s*like,\s*"#,
            options: .regularExpression
        ) != nil
        return candidateStillHasInterjection == false
    }

    private func isContextualYouKnowRemoved(rawText: String, candidate: CleanupCandidate) -> Bool {
        guard candidate.removedFillers.contains(where: { $0.caseInsensitiveCompare("you know") == .orderedSame }) else {
            return false
        }

        let rawRange = NSRange(rawText.startIndex..., in: rawText)
        let rawHasRemovableYouKnow = Self.removableYouKnowRegex.numberOfMatches(in: rawText, range: rawRange) > 0
        guard rawHasRemovableYouKnow else { return false }

        let candidateRange = NSRange(candidate.text.startIndex..., in: candidate.text)
        let candidateStillHasRemovableYouKnow = Self.removableYouKnowRegex.numberOfMatches(
            in: candidate.text,
            range: candidateRange
        ) > 0
        return candidateStillHasRemovableYouKnow == false
    }

    private func repairMarkersPresent(in text: String) -> Bool {
        RepairMarkerMatcher.containsRepairMarker(in: text)
    }

    private func confidenceAdjustment(raw: RawTranscript, candidate: CleanupCandidate) -> Double {
        let relevantEdits = candidate.appliedEdits.filter {
            $0.kind == .repairResolution || $0.kind == .lexiconCorrection
        }
        guard relevantEdits.isEmpty == false else { return 0 }

        let segmentConfidences = raw.segments.compactMap { segment -> Double? in
            guard let confidence = segment.confidence else { return nil }
            let normalizedSegment = normalize(segment.text)
            let overlaps = relevantEdits.contains { edit in
                let from = normalize(edit.from)
                let to = normalize(edit.to)
                return (!from.isEmpty && normalizedSegment.contains(from))
                    || (!to.isEmpty && normalizedSegment.contains(to))
            }
            return overlaps ? confidence : nil
        }

        let effectiveConfidence: Double?
        if segmentConfidences.isEmpty == false {
            effectiveConfidence = segmentConfidences.reduce(0, +) / Double(segmentConfidences.count)
        } else {
            effectiveConfidence = raw.avgConfidence
        }

        guard let effectiveConfidence else { return 0 }
        if effectiveConfidence < 0.70 {
            return 0.08
        }
        if effectiveConfidence > 0.90 {
            return -0.12
        }
        return 0
    }

    private func phoneticPenalty(candidate: CleanupCandidate) -> Double {
        candidate.rulePathID.contains("/phonetic-") ? 0.02 : 0
    }

    private func levenshteinDistance<Element: Equatable>(
        _ lhs: [Element],
        _ rhs: [Element]
    ) -> Int {
        if lhs == rhs { return 0 }
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)

        for (i, left) in lhs.enumerated() {
            current[0] = i + 1
            for (j, right) in rhs.enumerated() {
                let substitutionCost = left == right ? 0 : 1
                let deletion = previous[j + 1] + 1
                let insertion = current[j] + 1
                let substitution = previous[j] + substitutionCost
                current[j + 1] = min(deletion, insertion, substitution)
            }
            swap(&previous, &current)
        }

        return previous[rhs.count]
    }
}
