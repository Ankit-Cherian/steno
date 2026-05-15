import Testing
@testable import StenoKit

@Test("Cleanup turns dictated punctuation words into punctuation")
func cleanupTransformsDictatedPunctuationWords() async throws {
    #expect(try await runSymbolCleanup("hello comma world period") == "hello, world.")
    #expect(try await runSymbolCleanup("what time is it question mark") == "what time is it?")
    #expect(try await runSymbolCleanup("great exclamation point") == "great!")
}

@Test("Cleanup turns dictated paired symbols into symbol text")
func cleanupTransformsDictatedPairedSymbols() async throws {
    #expect(try await runSymbolCleanup("open paren foo close paren") == "(foo)")
    #expect(try await runSymbolCleanup("backtick todo backtick") == "`todo`")
}

@Test("Cleanup turns dictated prefix symbols into code-like text")
func cleanupTransformsDictatedPrefixSymbols() async throws {
    #expect(try await runSymbolCleanup("at sign environment") == "@environment")
    #expect(try await runSymbolCleanup("slash command") == "/command")
    #expect(try await runSymbolCleanup("forward slash build target") == "/build target")
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

@Test("Cleanup preserves ambiguous standalone symbol words")
func cleanupPreservesAmbiguousStandaloneSymbolWords() async throws {
    #expect(try await runSymbolCleanup("comma") == "comma")
    #expect(try await runSymbolCleanup("comma comma comma") == "comma comma comma")
    #expect(try await runSymbolCleanup("hello comma") == "hello comma")
}

@Test("Cleanup handles repeated paired symbols without stray spaces")
func cleanupTransformsRepeatedPairedSymbols() async throws {
    #expect(try await runSymbolCleanup("open paren open paren foo close paren close paren") == "((foo))")
}

@Test("Cleanup preserves spell out symbol instructions")
func cleanupPreservesSpellOutSymbolInstructions() async throws {
    #expect(try await runSymbolCleanup("Spell out open paren.") == "Spell out open paren.")
}

@Test("Cleanup preserves raw slash commands")
func cleanupPreservesRawSlashCommands() async throws {
    #expect(try await runSymbolCleanup("/build target") == "/build target")
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
