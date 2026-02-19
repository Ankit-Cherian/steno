import Foundation

public struct RuleBasedCleanupCandidateGenerator: Sendable {
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

        let variants = profileVariants(from: profile)
        for (pathID, variantProfile) in variants {
            let candidate = engine.buildCandidate(
                raw: raw,
                profile: variantProfile,
                lexicon: lexicon,
                rulePathID: pathID
            )
            candidates.append(candidate)
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
}
