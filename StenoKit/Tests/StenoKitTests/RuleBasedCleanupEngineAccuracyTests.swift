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

    #expect(cleaned.text == "we should head out now.")
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

private func runLocalCleanup(
    text: String,
    fillerPolicy: FillerPolicy
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
        lexicon: PersonalLexicon(entries: [])
    )
}
