import Foundation
import Testing
@testable import Steno
import StenoKit

@Test("Preferences saved with Tone, Command and Email values load and clean with working structures")
func retiredStyleValuesLoad() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoRetiredStyle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storageURL = directory.appendingPathComponent("preferences.json")

    var saved = AppPreferences.default
    saved.general.showOnboarding = false
    saved.globalStyleProfile = StyleProfile(
        name: "Default",
        tone: .professional,
        structureMode: .email,
        fillerPolicy: .balanced,
        commandPolicy: .transform
    )
    saved.appStyleProfiles = [
        "com.example.Terminal": StyleProfile(
            name: "Terminal",
            tone: .technical,
            structureMode: .command,
            fillerPolicy: .minimal,
            commandPolicy: .passthrough
        ),
    ]
    try JSONEncoder().encode(saved).write(to: storageURL)

    let store = AppPreferencesStore(storageURL: storageURL)
    let loaded = await store.load()
    #expect(await store.takeRecoveryNotices().isEmpty)
    #expect(loaded.globalStyleProfile.tone == .professional)
    #expect(loaded.globalStyleProfile.structureMode == .email)
    #expect(loaded.appStyleProfiles["com.example.Terminal"]?.structureMode == .command)

    let styles = StyleProfileService(
        globalProfile: loaded.globalStyleProfile,
        appProfiles: loaded.appStyleProfiles
    )
    let notes = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
    let terminal = AppContext(bundleIdentifier: "com.example.Terminal", appName: "Terminal")
    #expect(await styles.resolve(for: notes).structureMode == .paragraph)
    #expect(await styles.resolve(for: terminal).structureMode == .natural)
}
