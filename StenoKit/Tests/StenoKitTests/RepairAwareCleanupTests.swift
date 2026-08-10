import Testing
@testable import StenoKit

@Test("Cleanup resolves punctuated scratch that repairs by replacing the trailing phrase")
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
        raw: RawTranscript(text: "Send it to John, scratch that, Jane."),
        profile: profile,
        lexicon: PersonalLexicon(entries: [])
    )

    #expect(cleaned.text == "Send it to Jane.")
    #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }))
}

@Test("Cleanup preserves ambiguous unpunctuated repairs with a one-token prefix")
func cleanupPreservesAmbiguousSingleTokenPrefixRepair() async throws {
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

    #expect(cleaned.text == "Bob scratch that Jane")
    #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
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

@Test("Cleanup resolves dash-delimited repairs without leaking the delimiter")
func cleanupResolvesDashDelimitedRepairsWithoutLeakingDelimiter() async throws {
    let examples = [
        ("Tell Bob—erase that—Jane.", "Tell Jane."),
        ("Tell Bob–erase that–Jane.", "Tell Jane."),
    ]

    for (raw, expected) in examples {
        let cleaned = try await runRepairCleanup(raw)

        #expect(cleaned.text == expected)
        #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }))
    }
}

@Test("Cleanup preserves ambiguous unpunctuated repairs with a two-token prefix")
func cleanupPreservesAmbiguousTwoTokenPrefixRepair() async throws {
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

    #expect(cleaned.text == "Call Bob scratch that Jane")
    #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
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

@Test("Cleanup resolves punctuated never mind repairs at utterance start")
func cleanupResolvesPunctuatedNeverMindRepair() async throws {
    let cleaned = try await runRepairCleanup("Never mind. Call Jane.")

    #expect(cleaned.text == "Call Jane.")
    #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }))
}

@Test("Cleanup resolves punctuated I mean repairs at utterance start")
func cleanupResolvesPunctuatedIMeanRepair() async throws {
    let cleaned = try await runRepairCleanup("I mean. Call Jane.")

    #expect(cleaned.text == "Call Jane.")
    #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }))
}

@Test("Cleanup preserves punctuated no because repair intent is ambiguous")
func cleanupPreservesPunctuatedNo() async throws {
    let raw = "No. Call Jane."
    let cleaned = try await runRepairCleanup(raw)

    #expect(cleaned.text == raw)
    #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
}

@Test("Cleanup preserves non-repair no statements")
func cleanupPreservesNonRepairNoStatement() async throws {
    let cleaned = try await runRepairCleanup("No, I disagree with that plan.")

    #expect(cleaned.text == "No, I disagree with that plan.")
    #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
}

@Test("Cleanup preserves leading no when it directly negates a noun phrase")
func cleanupPreservesLeadingNoBeforeNounPhrase() async throws {
    let cleaned = try await runRepairCleanup("No sound broke the stillness of the night.")

    #expect(cleaned.text == "No sound broke the stillness of the night.")
    #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
}

@Test("Cleanup preserves short no thanks statements")
func cleanupPreservesNoThanksStatement() async throws {
    let cleaned = try await runRepairCleanup("No, thanks.")

    #expect(cleaned.text == "No, thanks.")
    #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
}

@Test("Cleanup preserves no maybe later statements")
func cleanupPreservesNoMaybeLaterStatement() async throws {
    let cleaned = try await runRepairCleanup("No, maybe later.")

    #expect(cleaned.text == "No, maybe later.")
    #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
}

@Test("Cleanup preserves leading no negation questions and quantities")
func cleanupPreservesLeadingNoNegationQuestionsAndQuantities() async throws {
    let examples = [
        "No, I've got it.",
        "No, did you see it?",
        "No, two is enough.",
        "No, thanks.",
        "No, maybe later.",
    ]

    for example in examples {
        let cleaned = try await runRepairCleanup(example)

        #expect(cleaned.text == example)
        #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
    }
}

@Test("Cleanup preserves contextual actually because repair intent is ambiguous")
func cleanupPreservesContextualActuallyWithPunctuationDrift() async throws {
    let raw = "Send it to Bob, actually. Jane Smith."
    let cleaned = try await runRepairCleanup(raw)

    #expect(cleaned.text == raw)
    #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
}

@Test("Cleanup preserves ordinary actually uses")
func cleanupPreservesOrdinaryActuallyUses() async throws {
    let examples = [
        "panda, actually",
        "how to actually add it",
        "actually wrote the code",
        "actually, I think this works",
    ]

    for example in examples {
        let cleaned = try await runRepairCleanup(example)

        #expect(cleaned.text == example)
        #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
    }
}

@Test("Cleanup preserves parenthetical actually before an adverb")
func cleanupPreservesParentheticalActuallyBeforeAdverb() async throws {
    let examples = [
        "I actually, really like it.",
        "The report is actually, very useful.",
    ]

    for example in examples {
        let cleaned = try await runRepairCleanup(example)

        #expect(cleaned.text == example)
        #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
    }
}

@Test("Cleanup preserves uncertain multi-marker repairs instead of producing malformed text")
func cleanupPreservesUncertainMultiMarkerRepairs() async throws {
    let raw = "Keep the heading. Never mind. Sorry, erase that. Don't change the heading."
    let cleaned = try await runRepairCleanup(raw)

    #expect(cleaned.text == raw)
    #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
}

@Test("Cleanup preserves literal never mind phrases")
func cleanupPreservesLiteralNeverMindPhrase() async throws {
    let cleaned = try await runRepairCleanup("Write never mind literally.")

    #expect(cleaned.text == "Write never mind literally.")
}

@Test("Cleanup preserves ordinary phrases that contain repair-marker words")
func cleanupPreservesOrdinaryRepairMarkerPhrases() async throws {
    let examples = [
        "Never mind the cost.",
        "I never mind doing the dishes.",
        "I never mind. Other people usually do.",
        "Delete that file from the folder.",
        "Erase that line from the document.",
        "Scratch that itch carefully.",
        "Please delete that file from the folder.",
        "Could you please delete that file?",
        "Ask Bob to delete that file.",
        "Call Bob and delete that file.",
        "I want to scratch that itch carefully.",
        "Go ahead and erase that line.",
        "Dogs scratch that itch when they are nervous.",
        "This is what I mean, exactly.",
        "This is what I mean. Exactly.",
        "The result, I mean, is surprising.",
        "The report, actually, is useful.",
        "Call Bob, never mind, the cost is low.",
        "No, go ahead.",
    ]

    for example in examples {
        let cleaned = try await runRepairCleanup(example)

        #expect(cleaned.text == example)
        #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
    }
}

@Test("Cleanup preserves metalinguistic repair-marker prose")
func cleanupPreservesMetalinguisticRepairMarkerProse() async throws {
    let examples = [
        "Use the phrase delete that in documentation.",
        "Use what I mean in the explanation.",
        "Tell me what I mean in this context.",
        "Use the word actually in the report.",
        "Call the result actually useful.",
        "The phrase, delete that, Bob used yesterday was rude.",
        "The words, scratch that, Jane wrote were literal.",
    ]

    for example in examples {
        let cleaned = try await runRepairCleanup(example)

        #expect(cleaned.text == example)
        #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
    }
}

@Test("Cleanup preserves telegraphic no statements")
func cleanupPreservesTelegraphicNoStatements() async throws {
    let examples = [
        "No. Refunds accepted.",
        "No. Sugar added.",
        "No. Parking allowed.",
        "No. Entry permitted.",
    ]

    for example in examples {
        let cleaned = try await runRepairCleanup(example)

        #expect(cleaned.text == example)
        #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
    }
}

@Test("Cleanup preserves ambiguous no and actually phrases instead of inferring repairs")
func cleanupPreservesAmbiguousNoAndActuallyPhrases() async throws {
    let examples = [
        "No. Call allowed.",
        "No. Email allowed.",
        "No. Message required.",
        "No. Change requested.",
        "No. Invite needed.",
        "No. Call for help.",
        "No. Tell anyone.",
        "Call Bob, actually, Monday.",
        "Email Jane, actually, Tuesday.",
        "Send it to Bob, actually, Monday.",
    ]

    for example in examples {
        let cleaned = try await runRepairCleanup(example)

        #expect(cleaned.text == example)
        #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
    }
}

@Test("Cleanup preserves action-marker phrases separated by sentence or incomplete discourse punctuation")
func cleanupPreservesAmbiguousActionMarkerPhrases() async throws {
    let examples = [
        "Call Bob. Delete that file.",
        "Email Bob. Erase that email.",
        "Tell Bob, scratch that itch.",
        "Ask Bob: delete that record.",
    ]

    for example in examples {
        let cleaned = try await runRepairCleanup(example)

        #expect(cleaned.text == example)
        #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
    }
}

@Test("Cleanup preserves telegraphic action-marker commands without explicit repair boundaries")
func cleanupPreservesTelegraphicActionMarkerCommands() async throws {
    let examples = [
        "Call Bob delete that file",
        "Email Bob erase that draft",
        "Tell Bob scratch that itch",
        "Ask Bob delete that record",
        "Send it to Bob erase that email",
    ]

    for example in examples {
        let cleaned = try await runRepairCleanup(example)

        #expect(cleaned.text == example)
        #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
    }
}

@Test("Cleanup resolves comma-delimited repair phrases")
func cleanupResolvesCommaDelimitedRepairPhrases() async throws {
    let examples = [
        ("Call Bob, never mind, call Jane.", "Call Jane."),
        ("Send the report to Bob, never mind, call Jane.", "Call Jane."),
        ("Send the quarterly report to Bob, never mind, email Jane.", "Email Jane."),
        ("I said Bob, I mean, Jane.", "I said Jane."),
    ]

    for (raw, expected) in examples {
        let cleaned = try await runRepairCleanup(raw)

        #expect(cleaned.text == expected)
        #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }))
    }
}

@Test("Cleanup preserves formatting outside a resolved repair")
func cleanupPreservesFormattingOutsideResolvedRepair() async throws {
    let examples = [
        ("Never mind. Call Jane.\n\nThen wait.", "Call Jane.\n\nThen wait."),
        ("I mean. call Jane.\n\nThen wait.", "call Jane.\n\nThen wait."),
        ("Never mind. Call Jane.\nKeep\tthis spacing.", "Call Jane.\nKeep\tthis spacing."),
    ]

    for (raw, expected) in examples {
        let cleaned = try await runRepairCleanup(raw)

        #expect(cleaned.text == expected)
        #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }))
    }
}

@Test("Never mind capitalization skips leading punctuation")
func neverMindCapitalizationSkipsLeadingPunctuation() async throws {
    let examples = [
        ("Never mind. \"call Jane\".", "\"Call Jane\"."),
        ("Never mind. (call Jane).", "(Call Jane)."),
    ]

    for (raw, expected) in examples {
        let cleaned = try await runRepairCleanup(raw)

        #expect(cleaned.text == expected)
        #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }))
    }
}

@Test("Cleanup preserves multi-word I mean corrections that cannot be replaced atomically")
func cleanupPreservesMultiwordIMeanCorrections() async throws {
    let examples = [
        "I said Bob Smith, I mean, Jane Doe.",
        "I typed Foo Bar, I mean, Baz Qux.",
    ]

    for example in examples {
        let cleaned = try await runRepairCleanup(example)

        #expect(cleaned.text == example)
        #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
    }
}

@Test("Cleanup preserves comma-delimited actually phrases")
func cleanupPreservesCommaDelimitedActuallyPhrases() async throws {
    let raw = "Send it to Bob, actually, Jane Smith."
    let cleaned = try await runRepairCleanup(raw)

    #expect(cleaned.text == raw)
    #expect(cleaned.edits.contains(where: { $0.kind == .repairResolution }) == false)
}

@Test("Cleanup preserves literal I mean phrases")
func cleanupPreservesLiteralIMeanPhrase() async throws {
    let cleaned = try await runRepairCleanup("Say I mean literally.")

    #expect(cleaned.text == "Say I mean literally.")
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

    let repairCandidates = try await generator.generateCandidates(
        raw: RawTranscript(text: "send it to John, scratch that, Jane"),
        profile: profile,
        lexicon: lexicon
    )
    let phoneticCandidates = try await generator.generateCandidates(
        raw: RawTranscript(text: "ping terso"),
        profile: profile,
        lexicon: lexicon
    )

    #expect(repairCandidates.contains(where: { $0.text.contains("send it to Jane") }))
    #expect(phoneticCandidates.contains(where: { $0.text.contains("TURSO") }))
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

private func runRepairCleanup(_ text: String) async throws -> CleanTranscript {
    let engine = RuleBasedCleanupEngine()
    let profile = StyleProfile(
        name: "Repair Fixture",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .passthrough
    )

    return try await engine.cleanup(
        raw: RawTranscript(text: text),
        profile: profile,
        lexicon: PersonalLexicon(entries: [])
    )
}
