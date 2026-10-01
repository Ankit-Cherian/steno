import Foundation
import Testing
@testable import StenoKit

private func profile(_ structure: StructureMode, tone: StyleTone = .natural) -> StyleProfile {
    StyleProfile(
        name: "Saved",
        tone: tone,
        structureMode: structure,
        fillerPolicy: .balanced,
        commandPolicy: .transform
    )
}

@Test("Settings offers only the structures that change the text")
func selectableStructures() {
    #expect(StructureMode.selectableCases == [.natural, .paragraph, .bullets])
    #expect(StructureMode.email.effective == .paragraph)
    #expect(StructureMode.command.effective == .natural)
    for mode in StructureMode.selectableCases {
        #expect(mode.effective == mode)
    }
}

@Test("Profiles saved with Email, Command or any tone still decode")
func savedRetiredValuesDecode() throws {
    for (structure, tone) in [("email", "professional"), ("command", "technical"), ("paragraph", "concise")] {
        let json = #"{"name":"Mail","tone":"\#(tone)","structureMode":"\#(structure)","fillerPolicy":"balanced","commandPolicy":"transform"}"#
        let decoded = try JSONDecoder().decode(StyleProfile.self, from: Data(json.utf8))
        #expect(decoded.structureMode.rawValue == structure)
        #expect(decoded.tone.rawValue == tone)
    }
}

@Test("A saved Email profile cleans like Paragraph, and Command like Natural")
func retiredStructuresUseNearestWorkingValue() async throws {
    let lexicon = PersonalLexicon(entries: defaultVocabularyEntries)
    for text in ["please open stenoh and check the build", "do not deploy before friday"] {
        let paragraph = try await RuleBasedCleanupEngine().cleanup(
            raw: dictatedTranscript(text), profile: profile(.paragraph), lexicon: lexicon
        ).text
        let email = try await RuleBasedCleanupEngine().cleanup(
            raw: dictatedTranscript(text), profile: profile(.email), lexicon: lexicon
        ).text
        #expect(email == paragraph)
        #expect(email.contains("Hi,") == false)
        #expect(email.contains("Thanks,") == false)

        let natural = try await RuleBasedCleanupEngine().cleanup(
            raw: dictatedTranscript(text), profile: profile(.natural), lexicon: lexicon
        ).text
        let command = try await RuleBasedCleanupEngine().cleanup(
            raw: dictatedTranscript(text), profile: profile(.command), lexicon: lexicon
        ).text
        #expect(command == natural)
    }

    let inserted = try await dictateThroughCoordinator("please open stenoh", profile: profile(.email, tone: .professional))
    #expect(inserted == "Please open Steno")
}

@Test("Resolved profiles carry the nearest working structure")
func resolvedProfilesAreNormalized() async {
    let service = StyleProfileService(
        globalProfile: profile(.email),
        appProfiles: ["com.example.Terminal": profile(.command)]
    )
    let notes = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
    let terminal = AppContext(bundleIdentifier: "com.example.Terminal", appName: "Terminal")
    #expect(await service.resolve(for: notes).structureMode == .paragraph)
    #expect(await service.resolve(for: terminal).structureMode == .natural)
}
