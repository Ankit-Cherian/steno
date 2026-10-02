import Foundation
import Testing
@testable import StenoKit

@Suite("Profile decoding tolerates values from newer versions")
struct ProfileDecodingTests {
    @Test("Unknown style values fall back and are reported")
    func styleProfileFallsBack() throws {
        let json = #"{"name":"Mail","tone":"poetic","structureMode":"outline","fillerPolicy":"extreme","commandPolicy":"auto"}"#
        let log = DecodingIssueLog()
        let profile = try JSONDecoder.recordingIssues(to: log).decode(StyleProfile.self, from: Data(json.utf8))
        #expect(profile == StyleProfile(
            name: "Mail",
            tone: .natural,
            structureMode: .natural,
            fillerPolicy: .balanced,
            commandPolicy: .transform
        ))
        #expect(log.replacedCount == 4)
    }

    @Test("Known style values decode unchanged and report nothing")
    func knownValuesRoundTrip() throws {
        let profile = StyleProfile(name: "Chat", tone: .friendly, structureMode: .bullets, fillerPolicy: .aggressive, commandPolicy: .passthrough)
        let log = DecodingIssueLog()
        let decoded = try JSONDecoder.recordingIssues(to: log).decode(StyleProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
        #expect(log.isEmpty)
    }

    @Test("A correction with an unknown phonetic policy keeps its words")
    func lexiconEntryPhoneticFallsBack() throws {
        let json = #"{"term":"kube control","preferred":"kubectl","scope":{"global":{}},"phoneticRecovery":"everywhere"}"#
        let entry = try JSONDecoder().decode(LexiconEntry.self, from: Data(json.utf8))
        #expect(entry.preferred == "kubectl")
        #expect(entry.phoneticRecovery == .off)
    }

    @Test("A text shortcut without a scope applies everywhere")
    func snippetScopeDefaultsToGlobal() throws {
        let json = #"{"id":"6E0F5D3C-4E7A-4B41-9E0C-1B0D2C3A4B5C","trigger":"sig","expansion":"Best regards"}"#
        let snippet = try JSONDecoder().decode(Snippet.self, from: Data(json.utf8))
        #expect(snippet.scope == .global)
    }

    @Test("A lossy array skips unreadable elements, including nulls")
    func lossyArraySkipsBadElements() throws {
        let json = #"[{"term":"a","preferred":"A","scope":{"global":{}}},null,{"term":"b"},{"term":"c","preferred":"C","scope":{"global":{}}}]"#
        let log = DecodingIssueLog()
        let entries = try JSONDecoder.recordingIssues(to: log).decode(LossyArray<LexiconEntry>.self, from: Data(json.utf8)).elements
        #expect(entries.map(\.preferred) == ["A", "C"])
        #expect(log.skippedCount == 2)
    }
}
