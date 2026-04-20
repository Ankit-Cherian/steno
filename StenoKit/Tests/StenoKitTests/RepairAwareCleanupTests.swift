import Testing
@testable import StenoKit

@Test("Cleanup resolves scratch that repairs by replacing the trailing phrase")
func cleanupResolvesScratchThatRepair() async throws {
    let engine = RuleBasedCleanupEngine()
    let profile = StyleProfile(
        name: "Repair Fixture",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .passthrough
    )

    let cleaned = try await engine.cleanup(
        raw: RawTranscript(text: "Send it to John scratch that Jane."),
        profile: profile,
        lexicon: PersonalLexicon(entries: [])
    )

    #expect(cleaned.text == "Send it to Jane.")
    #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }))
}

@Test("Cleanup resolves repairs with a one-token prefix")
func cleanupResolvesSingleTokenPrefixRepair() async throws {
    let engine = RuleBasedCleanupEngine()
    let profile = StyleProfile(
        name: "Repair Fixture",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .passthrough
    )

    let cleaned = try await engine.cleanup(
        raw: RawTranscript(text: "Bob scratch that Jane"),
        profile: profile,
        lexicon: PersonalLexicon(entries: [])
    )

    #expect(cleaned.text == "Jane")
    #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }))
}

@Test("Cleanup resolves punctuated one-token repair prefixes")
func cleanupResolvesPunctuatedSingleTokenPrefixRepair() async throws {
    let engine = RuleBasedCleanupEngine()
    let profile = StyleProfile(
        name: "Repair Fixture",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .passthrough
    )

    let cleaned = try await engine.cleanup(
        raw: RawTranscript(text: "Bob, scratch that, Jane."),
        profile: profile,
        lexicon: PersonalLexicon(entries: [])
    )

    #expect(cleaned.text == "Jane.")
    #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }))
}

@Test("Cleanup resolves repairs with a two-token prefix")
func cleanupResolvesTwoTokenPrefixRepair() async throws {
    let engine = RuleBasedCleanupEngine()
    let profile = StyleProfile(
        name: "Repair Fixture",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .passthrough
    )

    let cleaned = try await engine.cleanup(
        raw: RawTranscript(text: "Call Bob scratch that Jane"),
        profile: profile,
        lexicon: PersonalLexicon(entries: [])
    )

    #expect(cleaned.text == "Call Jane")
    #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }))
}

@Test("Cleanup preserves literal repair phrases when repair interpretation is destructive")
func cleanupPreservesLiteralRepairPhrase() async throws {
    let engine = RuleBasedCleanupEngine()
    let profile = StyleProfile(
        name: "Repair Fixture",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .passthrough
    )

    let cleaned = try await engine.cleanup(
        raw: RawTranscript(text: "Please type scratch that literally."),
        profile: profile,
        lexicon: PersonalLexicon(entries: [])
    )

    #expect(cleaned.text == "Please type scratch that literally.")
}

@Test("Candidate generator emits repair and phonetic recovery candidates")
func candidateGeneratorEmitsRepairAndPhoneticRecoveryCandidates() async throws {
    let generator = RuleBasedCleanupCandidateGenerator()
    let profile = StyleProfile(
        name: "Generator",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .passthrough
    )
    let lexicon = PersonalLexicon(entries: [
        .init(term: "TURSO", preferred: "TURSO", scope: .global, phoneticRecovery: .properNounEnglish)
    ])

    let candidates = try await generator.generateCandidates(
        raw: RawTranscript(text: "send it to John scratch that Jane and ping terso"),
        profile: profile,
        lexicon: lexicon
    )

    #expect(candidates.contains(where: { $0.text.contains("send it to Jane") }))
    #expect(candidates.contains(where: { $0.text.contains("TURSO") }))
}

@Test("Candidate generator does not use phonetic matching unless the entry opts in")
func candidateGeneratorRequiresPhoneticOptIn() async throws {
    let generator = RuleBasedCleanupCandidateGenerator()
    let profile = StyleProfile(
        name: "Generator",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .passthrough
    )
    let lexicon = PersonalLexicon(entries: [
        .init(term: "TURSO", preferred: "TURSO", scope: .global)
    ])

    let candidates = try await generator.generateCandidates(
        raw: RawTranscript(text: "ping terso"),
        profile: profile,
        lexicon: lexicon
    )

    #expect(candidates.contains(where: { $0.text.contains("TURSO") }) == false)
}

@Test("Candidate generator does not phonetic-match short all-caps acronyms")
func candidateGeneratorSkipsShortAllCapsPhonetics() async throws {
    let generator = RuleBasedCleanupCandidateGenerator()
    let profile = StyleProfile(
        name: "Generator",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .passthrough
    )
    let lexicon = PersonalLexicon(entries: [
        .init(term: "RT", preferred: "RT", scope: .global, phoneticRecovery: .properNounEnglish)
    ])

    let candidates = try await generator.generateCandidates(
        raw: RawTranscript(text: "the rate should stay literal"),
        profile: profile,
        lexicon: lexicon
    )

    #expect(candidates.contains(where: { $0.text.contains("RT") }) == false)
}
