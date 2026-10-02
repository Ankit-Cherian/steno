import Foundation

public struct LocalCleanupRanker: Sendable {
    public init() {}

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
        let semantic = semanticPreservationScore(
            rawText: raw.text,
            candidate: candidate,
            profile: profile
        )
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

    private func semanticPreservationScore(
        rawText: String,
        candidate: CleanupCandidate,
        profile: StyleProfile
    ) -> Double {
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
            let removedFillerWords = candidate.removedFillers.reduce(0) { count, filler in
                count + tokenizeWords(normalize(filler)).count
            }
            let accountedFillerDrops = min(dropped, removedFillerWords)
            let nonFillerDrops = dropped - accountedFillerDrops
            if nonFillerDrops > 0 {
                score -= min(0.4, Double(nonFillerDrops) / Double(rawWords.count))
            }
        }

        if profile.fillerPolicy == .aggressive {
            let optedInRemovals = candidate.removedFillers.filter { isAggressiveFiller($0) }.count
            if optedInRemovals > 0 {
                score += min(0.2, Double(optedInRemovals) * 0.1)
            }
        } else if candidate.removedFillers.isEmpty == false {
            score -= min(0.5, Double(candidate.removedFillers.count) * 0.25)
        }

        let repairEdits = candidate.appliedEdits.filter { $0.kind == .repairResolution }.count
        if repairEdits > 0 {
            if repairMarkersPresent(in: rawText) {
                score += min(0.35, Double(repairEdits) * 0.2)
            } else {
                score -= min(0.5, Double(repairEdits) * 0.25)
            }
            if repairMarkersPresent(in: rawText), !repairMarkersPresent(in: candidate.text) {
                score += 0.15
            }
        } else if repairMarkersPresent(in: rawText) && repairMarkersPresent(in: candidate.text) {
            score -= 0.2
        }

        let lexiconEdits = candidate.appliedEdits.filter { $0.kind == .lexiconCorrection }.count
        if lexiconEdits > 0 {
            score += min(0.2, Double(lexiconEdits) * 0.08)
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
        if text.contains(",.") || text.contains(".,") || text.contains(",?") || text.contains("..") {
            score -= 0.2
        }
        if text.range(of: #"[.!?]\s+[a-z]"#, options: .regularExpression) != nil {
            score -= 0.15
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

    private func isAggressiveFiller(_ filler: String) -> Bool {
        let normalized = filler.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let known: Set<String> = [
            "um",
            "uh",
            "i mean",
            "basically",
            "sort of",
            "kind of",
        ]
        return known.contains(normalized)
    }

    private func repairMarkersPresent(in text: String) -> Bool {
        RepairMarkerMatcher.containsRepairMarker(in: text)
    }

    /// Confidence gates only the corrections Steno infers by itself (phonetic recovery). Saved
    /// vocabulary and spoken corrections are explicit instructions and are never penalized here.
    private func confidenceAdjustment(raw: RawTranscript, candidate: CleanupCandidate) -> Double {
        guard isPhoneticRecovery(candidate) else { return 0 }
        let relevantEdits = candidate.appliedEdits.filter { $0.kind == .lexiconCorrection }
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
        isPhoneticRecovery(candidate) ? 0.02 : 0
    }

    private func isPhoneticRecovery(_ candidate: CleanupCandidate) -> Bool {
        candidate.rulePathID.contains("/phonetic-")
    }

    /// Word-level Levenshtein distance. Words are compared as integer IDs, the shared prefix and
    /// suffix are skipped, a pure deletion is counted directly, and otherwise only a diagonal band
    /// as wide as the distance is filled (widened until the result fits inside it), so a long
    /// dictation with scattered edits stays fast. The result is the same as the full table's.
    private func levenshteinDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        if lhs == rhs { return 0 }
        var ids: [String: Int] = [:]
        let intern = { (word: String) -> Int in
            if let id = ids[word] { return id }
            let id = ids.count
            ids[word] = id
            return id
        }
        var left = lhs.map(intern)[...]
        var right = rhs.map(intern)[...]
        while let l = left.first, let r = right.first, l == r {
            left = left.dropFirst()
            right = right.dropFirst()
        }
        while let l = left.last, let r = right.last, l == r {
            left = left.dropLast()
            right = right.dropLast()
        }
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }

        let a = Array(left)
        let b = Array(right)
        // When one side only deletes words from the other (filler removal, a resolved spoken
        // correction), the distance is exactly the difference in length.
        if a.count >= b.count, isSubsequence(b, of: a) { return a.count - b.count }
        if b.count > a.count, isSubsequence(a, of: b) { return b.count - a.count }
        var band = max(abs(a.count - b.count), 16)
        while true {
            if let distance = bandedDistance(a, b, band: band) {
                return distance
            }
            band *= 2
        }
    }

    private func isSubsequence(_ shorter: [Int], of longer: [Int]) -> Bool {
        var index = 0
        for word in longer where index < shorter.count && word == shorter[index] {
            index += 1
        }
        return index == shorter.count
    }

    /// The edit distance if it is at most `band`, otherwise nil. Once the band covers the whole
    /// table the distance is always returned.
    private func bandedDistance(_ a: [Int], _ b: [Int], band: Int) -> Int? {
        let n = a.count
        let m = b.count
        let exhaustive = band >= max(n, m)
        let outside = band + 1
        let width = m + 1
        var rows = [Int](repeating: outside, count: 2 * width)
        let distance = rows.withUnsafeMutableBufferPointer { rows -> Int in
            for j in 0...m {
                rows[j] = j <= band ? j : outside
            }
            for i in 1...n {
                let low = max(1, i - band)
                let high = min(m, i + band)
                guard low <= high else { return outside }
                let previous = ((i - 1) & 1) * width
                let current = (i & 1) * width
                rows[current + low - 1] = low == 1 && i <= band ? i : outside
                let word = a[i - 1]
                for j in low...high {
                    let substitution = rows[previous + j - 1] + (word == b[j - 1] ? 0 : 1)
                    let deletion = rows[previous + j] + 1
                    let insertion = rows[current + j - 1] + 1
                    rows[current + j] = min(substitution, deletion, insertion, outside)
                }
                if high < m {
                    rows[current + high + 1] = outside
                }
            }
            return rows[(n & 1) * width + m]
        }
        return distance <= band || exhaustive ? distance : nil
    }
}
