import Testing
@testable import StenoKit

private let bulletProfile = StyleProfile(
    name: "Bullets",
    tone: .natural,
    structureMode: .bullets,
    fillerPolicy: .balanced,
    commandPolicy: .transform
)

private func bullets(_ text: String) async throws -> String {
    try await RuleBasedCleanupEngine().cleanup(
        raw: dictatedTranscript(text),
        profile: bulletProfile,
        lexicon: PersonalLexicon(entries: [])
    ).text
}

@Test("Bullets keep decimals, thousands separators and email addresses in one item")
func bulletsKeepNumbersAndAddressesWhole() async throws {
    #expect(try await bullets("The cost is 1.25 dollars") == "- The cost is 1.25 dollars")
    #expect(try await bullets("We shipped 1,250 units") == "- We shipped 1,250 units")
    #expect(try await bullets("email me at sam@example.com") == "- Email me at sam@example.com")
    #expect(try await bullets("See https://example.com/a,b;c.html for details")
        == "- See https://example.com/a,b;c.html for details")
}

@Test("Bullets keep abbreviations inside their item")
func bulletsKeepAbbreviations() async throws {
    #expect(try await bullets("Ask Dr. Smith about it") == "- Ask Dr. Smith about it")
    #expect(try await bullets("Bring snacks, e.g. fruit") == "- Bring snacks\n- E.g. fruit")
    #expect(try await bullets("We moved to the U.S. last year") == "- We moved to the U.S. last year")
}

@Test("Bullets still split at clause punctuation followed by a space")
func bulletsSplitClauses() async throws {
    #expect(try await bullets("Buy milk, eggs; bread. Then call Sam.")
        == "- Buy milk\n- Eggs\n- Bread\n- Then call Sam")
    #expect(try await bullets("The total was 1.25. Pay by Friday.")
        == "- The total was 1.25\n- Pay by Friday")
}
