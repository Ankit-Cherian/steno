import Testing
@testable import StenoKit

@Test("Balanced filler policy preserves meaning-bearing like in noun phrase")
func balancedPolicyPreservesLikeInNounPhrase() async throws {
    let cleaned = try await runLocalCleanup(
        text: "From the respect paid her on all sides she seemed like a queen.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "From the respect paid her on all sides she seemed like a queen.")
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("like") == .orderedSame }) == false)
}

@Test("Balanced filler policy preserves like before determiner")
func balancedPolicyPreservesLikeBeforeDeterminer() async throws {
    let cleaned = try await runLocalCleanup(
        text: "Two innocent babies like that.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "Two innocent babies like that.")
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("like") == .orderedSame }) == false)
}

@Test("Balanced filler policy preserves like as verb complement")
func balancedPolicyPreservesLikeAsVerbComplement() async throws {
    let cleaned = try await runLocalCleanup(
        text: "The twin brother did something she didn't like and she turned his picture to the wall.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "The twin brother did something she didn't like and she turned his picture to the wall.")
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("like") == .orderedSame }) == false)
}

@Test("Balanced filler policy preserves multiple meaning-bearing like occurrences")
func balancedPolicyPreservesMultipleMeaningBearingLikes() async throws {
    let cleaned = try await runLocalCleanup(
        text: "I'd like to see what this lovely furniture looks like without such quantities of dust all over it.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "I'd like to see what this lovely furniture looks like without such quantities of dust all over it.")
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("like") == .orderedSame }) == false)
}

@Test("Balanced filler policy removes standalone interjectional like")
func balancedPolicyRemovesInterjectionalLike() async throws {
    let cleaned = try await runLocalCleanup(
        text: "Like, we should head out now.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "We should head out now.")
    #expect(cleaned.removedFillers == ["like"])
    #expect(cleaned.text.hasPrefix(",") == false)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("like") == .orderedSame }))
}

@Test("Balanced filler policy removes um and uh disfluencies")
func balancedPolicyRemovesUmAndUh() async throws {
    let cleaned = try await runLocalCleanup(
        text: "Um I think uh this should stay clear.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "I think this should stay clear.")
    #expect(cleaned.removedFillers == ["um", "uh"])
    #expect(cleaned.edits.filter { $0.kind == .fillerRemoval }.count == 2)
}

@Test("Balanced filler policy removes punctuated um and uh without leaving comma artifacts")
func balancedPolicyRemovesPunctuatedUmAndUh() async throws {
    let cleaned = try await runLocalCleanup(
        text: "Um, I think, uh, this should ship today.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "I think this should ship today.")
    #expect(cleaned.removedFillers == ["um", "uh"])
    #expect(cleaned.text.hasPrefix(",") == false)
    #expect(cleaned.text.contains(",,") == false)
}

@Test("Balanced filler cleanup preserves normal commas before pronouns")
func balancedPolicyPreservesNormalCommasBeforePronouns() async throws {
    let examples = [
        "my Mac, it keeps the capture hot.",
        "programmatically, you can wire this through the coordinator.",
        "the code, he said, was ready.",
        "open it, that tab has the trace.",
    ]

    for example in examples {
        let cleaned = try await runLocalCleanup(text: example, fillerPolicy: .balanced)

        #expect(cleaned.text == example)
        #expect(cleaned.removedFillers.isEmpty)
    }
}

@Test("Balanced candidate generation does not emit aggressive filler removals")
func balancedCandidateGenerationDoesNotEmitAggressiveFillerRemovals() async throws {
    let candidates = try await runGeneratedCandidates(
        text: "i mean this is basically ready.",
        fillerPolicy: .balanced
    )

    #expect(candidates.allSatisfy { candidate in
        candidate.removedFillers.contains { filler in
            filler == "i mean" || filler == "basically"
        } == false
    })
}

@Test("Aggressive candidate generation may emit aggressive filler removals")
func aggressiveCandidateGenerationMayEmitAggressiveFillerRemovals() async throws {
    let candidates = try await runGeneratedCandidates(
        text: "i mean this is basically ready.",
        fillerPolicy: .aggressive
    )

    #expect(candidates.contains { candidate in
        candidate.removedFillers.contains("i mean")
            || candidate.removedFillers.contains("basically")
    })
}

@Test("Balanced cleanup does not select aggressive filler removals")
func balancedCleanupDoesNotSelectAggressiveFillerRemovals() async throws {
    let cleaned = try await runLocalCleanup(
        text: "i mean this is basically ready.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "i mean this is basically ready.")
    #expect(cleaned.removedFillers.isEmpty)
}

@Test("Balanced filler removal capitalizes a sentence after leading filler removal")
func balancedFillerRemovalCapitalizesSentenceAfterLeadingFillerRemoval() async throws {
    let cleaned = try await runLocalCleanup(
        text: "um this should start clean.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "This should start clean.")
    #expect(cleaned.removedFillers == ["um"])
}

@Test("Balanced filler removal cleans sentence-boundary punctuation artifacts")
func balancedFillerRemovalCleansSentenceBoundaryPunctuationArtifacts() async throws {
    let cleaned = try await runLocalCleanup(
        text: "This is. um, okay.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "This is. Okay.")
    #expect(cleaned.text.contains(".,") == false)
    #expect(cleaned.removedFillers == ["um"])
}

@Test("Balanced filler removal avoids double spaces after comma-surrounded filler")
func balancedFillerRemovalAvoidsDoubleSpacesAfterCommaSurroundedFiller() async throws {
    let cleaned = try await runLocalCleanup(
        text: "Make it clear, you know, make it useful.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "Make it clear, make it useful.")
    #expect(cleaned.text.contains("  ") == false)
    #expect(cleaned.removedFillers == ["you know"])
}

@Test("Balanced filler removal avoids comma-question punctuation artifacts")
func balancedFillerRemovalAvoidsCommaQuestionPunctuationArtifacts() async throws {
    let cleaned = try await runLocalCleanup(
        text: "Wait, um? Are we ready.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "Wait? Are we ready.")
    #expect(cleaned.text.contains(",?") == false)
    #expect(cleaned.removedFillers == ["um"])
}

@Test("Balanced filler policy preserves you know before determiner")
func balancedPolicyPreservesYouKnowBeforeDeterminer() async throws {
    let cleaned = try await runLocalCleanup(
        text: "I think you know the answer to that question.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "I think you know the answer to that question.")
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("you know") == .orderedSame }) == false)
}

@Test("Balanced filler policy preserves you know before pronoun")
func balancedPolicyPreservesYouKnowBeforePronoun() async throws {
    let cleaned = try await runLocalCleanup(
        text: "I told him you know he was right about everything.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "I told him you know he was right about everything.")
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("you know") == .orderedSame }) == false)
}

@Test("Balanced filler policy preserves you know before wh word")
func balancedPolicyPreservesYouKnowBeforeWhWord() async throws {
    let cleaned = try await runLocalCleanup(
        text: "She explained you know what happened at the meeting.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "She explained you know what happened at the meeting.")
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("you know") == .orderedSame }) == false)
}

@Test("Balanced filler policy preserves you know before if")
func balancedPolicyPreservesYouKnowBeforeIf() async throws {
    let cleaned = try await runLocalCleanup(
        text: "I think you know if we should ship this today.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "I think you know if we should ship this today.")
    #expect(cleaned.removedFillers.isEmpty)
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("you know") == .orderedSame }) == false)
}

@Test("Balanced filler policy removes sentence final you know")
func balancedPolicyRemovesSentenceFinalYouKnow() async throws {
    let cleaned = try await runLocalCleanup(
        text: "The team was ready you know.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "The team was ready.")
    #expect(cleaned.removedFillers == ["you know"])
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("you know") == .orderedSame }))
}

@Test("Balanced filler policy removes you know before unprotected continuation")
func balancedPolicyRemovesYouKnowBeforeUnprotectedContinuation() async throws {
    let cleaned = try await runLocalCleanup(
        text: "The report was you know solid and everyone agreed with the findings.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "The report was solid and everyone agreed with the findings.")
    #expect(cleaned.removedFillers == ["you know"])
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("you know") == .orderedSame }))
}

@Test("Balanced filler policy removes um but preserves contextual you know")
func balancedPolicyRemovesUmButPreservesContextualYouKnow() async throws {
    let cleaned = try await runLocalCleanup(
        text: "Um I think you know she was the best candidate for the position.",
        fillerPolicy: .balanced
    )

    #expect(cleaned.text == "I think you know she was the best candidate for the position.")
    #expect(cleaned.removedFillers == ["um"])
    #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("you know") == .orderedSame }) == false)
}

@Test("Balanced filler policy preserves fixed phrases around you know")
func balancedPolicyPreservesFixedPhrasesAroundYouKnow() async throws {
    let examples = [
        "I'll let you know.",
        "As you know, this is risky.",
        "Everything you know about this matters.",
        "Everything you know in that file matters.",
        "Do you know?",
    ]

    for example in examples {
        let cleaned = try await runLocalCleanup(text: example, fillerPolicy: .balanced)

        #expect(cleaned.text == example)
        #expect(cleaned.removedFillers.isEmpty)
        #expect(cleaned.edits.contains(where: { $0.kind == .fillerRemoval && $0.from.caseInsensitiveCompare("you know") == .orderedSame }) == false)
    }
}

@Test("Cleanup does not apply dangerous common-word lexicon entries in ordinary prose")
func cleanupDoesNotApplyDangerousCommonWordLexiconEntriesInOrdinaryProse() async throws {
    let lexicon = PersonalLexicon(entries: [
        .init(term: "cloud", preferred: "Nimbus", scope: .global)
    ])
    let examples = [
        "stored in the cloud",
        "cloud storage",
        "upload it to the cloud",
    ]

    for example in examples {
        let cleaned = try await runLocalCleanup(
            text: example,
            fillerPolicy: .balanced,
            lexicon: lexicon
        )

        #expect(cleaned.text == example)
        #expect(cleaned.edits.contains(where: { $0.kind == .lexiconCorrection }) == false)
    }
}

private func runLocalCleanup(
    text: String,
    fillerPolicy: FillerPolicy,
    lexicon: PersonalLexicon = PersonalLexicon(entries: [])
) async throws -> CleanTranscript {
    let engine = RuleBasedCleanupEngine()
    let profile = StyleProfile(
        name: "Accuracy Fixture",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: fillerPolicy,
        commandPolicy: .passthrough
    )

    return try await engine.cleanup(
        raw: RawTranscript(text: text),
        profile: profile,
        lexicon: lexicon
    )
}

private func runGeneratedCandidates(
    text: String,
    fillerPolicy: FillerPolicy
) async throws -> [CleanupCandidate] {
    let generator = RuleBasedCleanupCandidateGenerator()
    let profile = StyleProfile(
        name: "Candidate Fixture",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: fillerPolicy,
        commandPolicy: .passthrough
    )

    return try await generator.generateCandidates(
        raw: RawTranscript(text: text),
        profile: profile,
        lexicon: PersonalLexicon(entries: [])
    )
}
