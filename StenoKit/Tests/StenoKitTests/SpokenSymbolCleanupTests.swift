import Testing
@testable import StenoKit

@Test("Cleanup preserves dictated punctuation phrases without explicit symbol intent")
func cleanupPreservesDictatedPunctuationWithoutExplicitIntent() async throws {
    #expect(try await runSymbolCleanup("what time is it question mark") == "what time is it question mark")
    #expect(try await runSymbolCleanup("great exclamation point") == "great exclamation point")
}

@Test("Cleanup preserves dictated paired symbols without explicit symbol intent")
func cleanupPreservesDictatedPairedSymbolsWithoutExplicitIntent() async throws {
    #expect(try await runSymbolCleanup("open paren foo close paren") == "open paren foo close paren")
    #expect(try await runSymbolCleanup("backtick todo backtick") == "backtick todo backtick")
}

@Test("Cleanup preserves dictated prefix symbols without explicit symbol intent")
func cleanupPreservesDictatedPrefixSymbolsWithoutExplicitIntent() async throws {
    #expect(try await runSymbolCleanup("at sign environment") == "at sign environment")
    #expect(try await runSymbolCleanup("slash command") == "slash command")
    #expect(try await runSymbolCleanup("forward slash build target") == "forward slash build target")
}

@Test("Cleanup preserves literal spoken symbol phrases")
func cleanupPreservesLiteralSpokenSymbolPhrases() async throws {
    #expect(try await runSymbolCleanup("Write slash command literally.") == "Write slash command literally.")
    let openParenLiteral = try await runSymbolCleanup("Please type open paren literally.")
    #expect(openParenLiteral == "Please type open paren literally.", "Actual: \(openParenLiteral)")
}

@Test("Cleanup preserves prose spoken slash phrase")
func cleanupPreservesProseSlashPhrase() async throws {
    #expect(try await runSymbolCleanup("I said slash command yesterday.") == "I said slash command yesterday.")
    #expect(try await runSymbolCleanup("slash command was mentioned in the meeting") == "slash command was mentioned in the meeting")
    #expect(try await runSymbolCleanup("forward slash build target was discussed") == "forward slash build target was discussed")
    #expect(try await runSymbolCleanup("at sign environment variable was discussed") == "at sign environment variable was discussed")
}

@Test("Cleanup preserves prose punctuation words")
func cleanupPreservesProsePunctuationWords() async throws {
    #expect(try await runSymbolCleanup("the comma key on my keyboard") == "the comma key on my keyboard")
    #expect(try await runSymbolCleanup("please add a comma there") == "please add a comma there")
    #expect(try await runSymbolCleanup("it ended with a question mark") == "it ended with a question mark")
    #expect(try await runSymbolCleanup("period of waiting") == "period of waiting")
    #expect(try await runSymbolCleanup("I want a backtick around this code") == "I want a backtick around this code")
}

@Test("Cleanup preserves existing punctuation around spoken-symbol phrases")
func cleanupPreservesExistingPunctuationAroundSpokenSymbolPhrases() async throws {
    #expect(try await runSymbolCleanup("What, exactly, is this question mark") == "What, exactly, is this question mark")
    #expect(try await runSymbolCleanup("Use foo-bar then say question mark") == "Use foo-bar then say question mark")
    #expect(try await runSymbolCleanup("Hello, world question mark") == "Hello, world question mark")
}

@Test("Cleanup preserves symbol words used inside noun compounds")
func cleanupPreservesSymbolWordsInsideNounCompounds() async throws {
    #expect(try await runSymbolCleanup("The probation period ends tomorrow.") == "The probation period ends tomorrow.")
    #expect(try await runSymbolCleanup("The billing period starts Monday.") == "The billing period starts Monday.")
    #expect(try await runSymbolCleanup("I prefer the Oxford comma in prose.") == "I prefer the Oxford comma in prose.")
    #expect(try await runSymbolCleanup("Billing period starts Monday.") == "Billing period starts Monday.")
    #expect(try await runSymbolCleanup("Oxford comma rules are debated.") == "Oxford comma rules are debated.")
    #expect(try await runSymbolCleanup("A three-month probation period ends tomorrow.") == "A three-month probation period ends tomorrow.")
    #expect(try await runSymbolCleanup("Billing period starts Monday comma July fifth.") == "Billing period starts Monday comma July fifth.")
    #expect(try await runSymbolCleanup("Explain the Oxford comma then say question mark") == "Explain the Oxford comma then say question mark")
    #expect(try await runSymbolCleanup("I studied the Oxford comma and billing period") == "I studied the Oxford comma and billing period")
    #expect(try await runSymbolCleanup("I prefer question mark notation") == "I prefer question mark notation")
    #expect(try await runSymbolCleanup("I said question mark during the demo") == "I said question mark during the demo")
}

@Test("Cleanup preserves symbol phrases in comparative and reported prose")
func cleanupPreservesSymbolPhrasesInComparativeAndReportedProse() async throws {
    let examples = [
        "Oxford comma preferences differ from serial comma preferences.",
        "Oxford question mark preferences vary by team.",
        "I heard question mark during the demo.",
        "I repeated question mark during the demo.",
        "I uttered question mark during the demo.",
        "We compare question mark preferences and exclamation point preferences.",
        "I heard question mark",
        "I repeated question mark",
        "The title is Question Mark",
    ]

    for example in examples {
        #expect(try await runSymbolCleanup(example) == example)
    }
}

@Test("Cleanup preserves mixed literal and dictated backticks")
func cleanupPreservesMixedLiteralAndDictatedBackticks() async throws {
    let examples = [
        "Use `code backtick now",
        "Use backtick code ` now",
    ]

    for example in examples {
        #expect(try await runSymbolCleanup(example) == example)
    }
}

@Test("Cleanup preserves ambiguous bare punctuation sequences")
func cleanupPreservesAmbiguousBarePunctuationSequences() async throws {
    #expect(try await runSymbolCleanup("hello comma world period") == "hello comma world period")
    #expect(try await runSymbolCleanup("The report comma however comma is ready.") == "The report comma however comma is ready.")
}

@Test("Cleanup preserves ambiguous standalone symbol words")
func cleanupPreservesAmbiguousStandaloneSymbolWords() async throws {
    #expect(try await runSymbolCleanup("comma") == "comma")
    #expect(try await runSymbolCleanup("comma comma comma") == "comma comma comma")
    #expect(try await runSymbolCleanup("hello comma") == "hello comma")
}

@Test("Cleanup preserves repeated paired-symbol phrases")
func cleanupPreservesRepeatedPairedSymbolPhrases() async throws {
    let raw = "open paren open paren foo close paren close paren"
    #expect(try await runSymbolCleanup(raw) == raw)
}

@Test("Cleanup preserves adjacent opposing symbol phrases")
func cleanupPreservesAdjacentOpposingSymbolPhrases() async throws {
    #expect(try await runSymbolCleanup("Use open paren close paren now") == "Use open paren close paren now")
    #expect(try await runSymbolCleanup("Use open paren question mark close paren now") == "Use open paren question mark close paren now")
}

@Test("Cleanup preserves Unicode whitespace before a spoken-symbol phrase")
func cleanupPreservesUnicodeWhitespaceBeforeSpokenSymbolPhrase() async throws {
    let raw = "what time is it\u{00A0}question mark"
    #expect(try await runSymbolCleanup(raw) == raw)
}

@Test("Cleanup preserves mixed literal and spoken parentheses")
func cleanupPreservesMixedLiteralAndSpokenParentheses() async throws {
    let example = "Use (open paren foo close paren"
    #expect(try await runSymbolCleanup(example) == example)
}

@Test("Candidate generator rejects ambiguous spoken-symbol interpretations")
func candidateGeneratorRejectsAmbiguousSpokenSymbolInterpretations() async throws {
    let generator = RuleBasedCleanupCandidateGenerator()
    let profile = StyleProfile(
        name: "Symbol Admission Fixture",
        tone: .technical,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .passthrough
    )
    let examples = [
        "Oxford comma preferences differ from serial comma preferences.",
        "I heard question mark",
        "Use `code backtick now",
        "Use (open paren foo close paren",
    ]

    for example in examples {
        let candidates = try await generator.generateCandidates(
            raw: RawTranscript(text: example),
            profile: profile,
            lexicon: PersonalLexicon(entries: [])
        )

        #expect(candidates.contains(where: { $0.rulePathID.contains("spoken-symbols") }) == false)
    }
}

@Test("Cleanup preserves spell out symbol instructions")
func cleanupPreservesSpellOutSymbolInstructions() async throws {
    #expect(try await runSymbolCleanup("Spell out open paren.") == "Spell out open paren.")
}

@Test("Cleanup preserves raw slash commands")
func cleanupPreservesRawSlashCommands() async throws {
    #expect(try await runSymbolCleanup("/build target") == "/build target")
}

@Test("Cleanup preserves spoken-symbol phrases without an explicit symbol mode")
func cleanupPreservesSpokenSymbolPhrasesWithoutExplicitMode() async throws {
    let examples = [
        "Did she say question mark",
        "Did the title say Question Mark",
        "Is the title Question Mark",
        "What is Question Mark",
        "What is a question mark",
        "Where is the question mark",
        "How do I type a question mark",
        "No exclamation point",
        "Open paren means start and close paren",
        "Backtick means code and backtick",
        "Slash command syntax",
        "Forward slash symbol",
        "At sign meaning",
    ]

    for example in examples {
        #expect(try await runSymbolCleanup(example) == example)
    }
}

@Test("Candidate generator does not infer spoken-symbol intent")
func candidateGeneratorDoesNotInferSpokenSymbolIntent() async throws {
    let generator = RuleBasedCleanupCandidateGenerator()
    let profile = StyleProfile(
        name: "Symbol Admission Fixture",
        tone: .technical,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .passthrough
    )
    let examples = [
        "what time is it question mark",
        "great exclamation point",
        "open paren foo close paren",
        "backtick todo backtick",
        "at sign environment",
        "slash command",
        "forward slash build target",
    ]

    for example in examples {
        let candidates = try await generator.generateCandidates(
            raw: RawTranscript(text: example),
            profile: profile,
            lexicon: PersonalLexicon(entries: [])
        )

        #expect(candidates.contains(where: { $0.rulePathID.contains("spoken-symbols") }) == false)
    }
}

private func runSymbolCleanup(_ text: String) async throws -> String {
    let engine = RuleBasedCleanupEngine()
    let profile = StyleProfile(
        name: "Symbol Fixture",
        tone: .technical,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .passthrough
    )

    let cleaned = try await engine.cleanup(
        raw: RawTranscript(text: text),
        profile: profile,
        lexicon: PersonalLexicon(entries: [])
    )
    return cleaned.text
}
