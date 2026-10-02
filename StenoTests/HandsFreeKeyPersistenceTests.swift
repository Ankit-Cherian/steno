import Foundation
import Testing
@testable import Steno

@Suite("Hands-free key persistence")
struct HandsFreeKeyPersistenceTests {
    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoHandsFreeKey-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("preferences.json")
    }

    @Test("Disabled survives a save and reload")
    func disabledSurvivesReload() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var preferences = AppPreferences.default
        preferences.hotkeys.handsFreeGlobalKeyCode = nil
        #expect((try? await AppPreferencesStore(storageURL: url).save(preferences).get()) != nil)

        let reloaded = await AppPreferencesStore(storageURL: url).load()
        #expect(reloaded.hotkeys.handsFreeGlobalKeyCode == nil)
    }

    @Test("Disabled is written as an explicit null")
    func disabledIsExplicitNull() throws {
        let hotkeys = AppPreferences.Hotkeys(optionPressToTalkEnabled: true, handsFreeGlobalKeyCode: nil)
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(hotkeys)) as? [String: Any]
        )
        #expect(object["handsFreeGlobalKeyCode"] is NSNull)
    }

    @Test("An absent key keeps the original F18 default; a chosen key round-trips")
    func absentKeyUsesLegacyDefault() throws {
        let absent = try JSONDecoder().decode(
            AppPreferences.Hotkeys.self,
            from: Data(#"{"optionPressToTalkEnabled":true}"#.utf8)
        )
        #expect(absent.handsFreeGlobalKeyCode == 79)

        let chosen = AppPreferences.Hotkeys(optionPressToTalkEnabled: false, handsFreeGlobalKeyCode: 105)
        let decoded = try JSONDecoder().decode(AppPreferences.Hotkeys.self, from: JSONEncoder().encode(chosen))
        #expect(decoded == chosen)
    }

    @Test("A file with Disabled still loads in 1.0.0")
    func disabledFileLoadsInReleasedVersion() async throws {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var preferences = AppPreferences.default
        preferences.hotkeys.handsFreeGlobalKeyCode = nil
        await AppPreferencesStore(storageURL: url).save(preferences)

        let released = try JSONDecoder().decode(Released100Preferences.Preferences.self, from: Data(contentsOf: url))
        // 1.0.0 reads null as its F18 default; the file is not discarded.
        #expect(released.hotkeys.handsFreeGlobalKeyCode == 79)
    }
}
