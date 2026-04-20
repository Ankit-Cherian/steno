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
