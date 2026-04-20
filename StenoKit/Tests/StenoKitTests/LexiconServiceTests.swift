import Foundation
import Testing
@testable import StenoKit

@Test("Lexicon applies global and app-scoped replacements")
func lexiconGlobalAndScopedReplacement() async throws {
    let service = PersonalLexiconService()
    await service.upsert(term: "stenoh", preferred: "Steno", scope: .global)
    await service.upsert(term: "cursor", preferred: "Cursor IDE", scope: .app(bundleID: "com.todesktop.230313mzl4w4u92"))

    let generalContext = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
    let ideContext = AppContext(bundleIdentifier: "com.todesktop.230313mzl4w4u92", appName: "Cursor", isIDE: true)

    let general = await service.apply(to: "hey stenoh open cursor", appContext: generalContext)
    let ide = await service.apply(to: "hey stenoh open cursor", appContext: ideContext)

    #expect(general == "hey Steno open cursor")
    #expect(ide == "hey Steno open Cursor IDE")
}

@Test("Lexicon applies aliases and prioritizes app hot terms")
func lexiconAliasesAndHotTerms() async throws {
    let service = PersonalLexiconService()
    await service.upsert(
        term: "TURSO",
        preferred: "TURSO",
        scope: .app(bundleID: "com.todesktop.230313mzl4w4u92"),
        aliases: ["terso", "ter so"]
    )
    await service.upsert(term: "steno kit", preferred: "StenoKit", scope: .global)

    let ideContext = AppContext(
        bundleIdentifier: "com.todesktop.230313mzl4w4u92",
        appName: "Cursor",
        isIDE: true
    )

    let result = await service.applyWithEdits(
        to: "ping ter so about steno kit",
        appContext: ideContext
    )
    let hotTerms = await service.hotTerms(for: ideContext, limit: 4)

    #expect(result.text == "ping TURSO about StenoKit")
    #expect(result.edits.contains(where: { $0.kind == .lexiconCorrection && $0.to == "TURSO" }))
    #expect(hotTerms == ["TURSO", "StenoKit"])
}

@Test("LexiconEntry decodes legacy payloads without aliases")
func lexiconEntryDecodesLegacyPayloadWithoutAliases() throws {
    let data = Data(#"{"term":"stenoh","preferred":"Steno","scope":{"global":{}}}"#.utf8)
    let decoder = JSONDecoder()

    let entry = try decoder.decode(LexiconEntry.self, from: data)

    #expect(entry.term == "stenoh")
    #expect(entry.preferred == "Steno")
    #expect(entry.aliases.isEmpty)
    #expect(entry.scope == .global)
}

@Test("LexiconEntry decodes legacy payloads without phonetic policy")
func lexiconEntryDecodesLegacyPayloadWithoutPhoneticPolicy() throws {
    let data = Data(#"{"term":"turso","preferred":"TURSO","scope":{"global":{}},"aliases":["terso"]}"#.utf8)
    let decoder = JSONDecoder()

    let entry = try decoder.decode(LexiconEntry.self, from: data)

    #expect(entry.aliases == ["terso"])
    #expect(entry.phoneticRecovery == .off)
}
