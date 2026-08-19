import Foundation
import Testing
@testable import Steno

@Suite("Live context preferences")
struct AppPreferencesLiveContextTests {
    @Test
    func defaultsKeepBothFeaturesOptInUntilAcceptance() {
        let preferences = AppPreferences.default

        #expect(!preferences.dictation.showLiveTranscriptWhileRecording)
        #expect(!preferences.dictation.useNearbyTextForContinuation)
    }

    @Test
    func decodingLegacyPreferencesDoesNotBroadenCollectionOrDisplay() throws {
        let encoded = try JSONEncoder().encode(AppPreferences.default)
        var root = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var dictation = try #require(root["dictation"] as? [String: Any])
        dictation.removeValue(forKey: "showLiveTranscriptWhileRecording")
        dictation.removeValue(forKey: "useNearbyTextForContinuation")
        root["dictation"] = dictation

        let legacyData = try JSONSerialization.data(withJSONObject: root)
        let migrated = try JSONDecoder().decode(AppPreferences.self, from: legacyData)

        #expect(!migrated.dictation.showLiveTranscriptWhileRecording)
        #expect(!migrated.dictation.useNearbyTextForContinuation)
    }

    @Test
    func encodeDecodePreservesExplicitlyEnabledValues() throws {
        var preferences = AppPreferences.default
        preferences.dictation.showLiveTranscriptWhileRecording = true
        preferences.dictation.useNearbyTextForContinuation = true

        let encoded = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: encoded)

        #expect(decoded.dictation.showLiveTranscriptWhileRecording)
        #expect(decoded.dictation.useNearbyTextForContinuation)
    }

    @Test
    func storePersistsBothFeatureToggles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoPreferencesTests-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("preferences.json")
        let store = AppPreferencesStore(storageURL: storageURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        var preferences = AppPreferences.default
        preferences.dictation.showLiveTranscriptWhileRecording = true
        preferences.dictation.useNearbyTextForContinuation = true
        await store.save(preferences)

        let loaded = await store.load()
        #expect(loaded.dictation.showLiveTranscriptWhileRecording)
        #expect(loaded.dictation.useNearbyTextForContinuation)

        let persisted = try JSONDecoder().decode(
            AppPreferences.self,
            from: Data(contentsOf: storageURL)
        )
        #expect(persisted.dictation.showLiveTranscriptWhileRecording)
        #expect(persisted.dictation.useNearbyTextForContinuation)
    }
}
