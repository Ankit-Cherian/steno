import Foundation
import Testing
@testable import Steno

@Suite("Isolated preferences storage")
struct AppPreferencesStoreIsolationTests {
    @Test("New appearance defaults preserve previously stored and legacy accent choices")
    func appearanceCompatibility() throws {
        #expect(AppPreferences.Appearance().accent == .citron)
        let legacy = try JSONDecoder().decode(AppPreferences.Appearance.self, from: Data("{}".utf8))
        #expect(legacy.accent == .dodger)
        let blue = AppPreferences.Appearance(accent: .dodger)
        let decoded = try JSONDecoder().decode(AppPreferences.Appearance.self, from: JSONEncoder().encode(blue))
        #expect(decoded == blue)
        #expect(decoded.accent == .dodger)
    }

    @Test("Explicit stores load only their own preferences and a missing fixture stays empty")
    func explicitStoresRemainIndependent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoPreferencesIsolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = AppPreferencesStore(storageURL: directory.appendingPathComponent("first/preferences.json"))
        let secondURL = directory.appendingPathComponent("second/preferences.json")
        let second = AppPreferencesStore(storageURL: secondURL)
        var preferences = AppPreferences.default
        preferences.hotkeys.handsFreeGlobalKeyCode = 107
        await first.save(preferences)
        let loadedFirst = await first.load()
        let loadedSecond = await second.load()
        #expect(loadedFirst.hotkeys.handsFreeGlobalKeyCode == 107)
        #expect(loadedSecond.hotkeys.handsFreeGlobalKeyCode == AppPreferences.default.hotkeys.handsFreeGlobalKeyCode)
        #expect(!FileManager.default.fileExists(atPath: secondURL.deletingLastPathComponent().path))
    }
}
