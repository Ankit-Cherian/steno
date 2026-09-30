import Foundation
import Testing
@testable import Steno
import StenoKit

@Suite("Preferences damaged-file recovery", .serialized)
struct AppPreferencesRecoveryTests {
    private struct Fixture {
        let directory: URL
        let storageURL: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("StenoPreferencesRecovery-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            storageURL = directory.appendingPathComponent("preferences.json")
        }

        func store() -> AppPreferencesStore {
            AppPreferencesStore(storageURL: storageURL)
        }

        /// A 1.0-format file holding the user's own vocabulary, shortcuts and profiles.
        func currentFormatObject() throws -> [String: Any] {
            var preferences = AppPreferences.default
            preferences.general.showOnboarding = false
            preferences.hotkeys.handsFreeGlobalKeyCode = 105
            preferences.lexiconEntries.append(LexiconEntry(term: "kube control", preferred: "kubectl", scope: .global))
            preferences.lexiconEntries.append(
                LexiconEntry(term: "post gres", preferred: "Postgres", scope: .app(bundleID: "com.example.Editor"))
            )
            preferences.snippets = [
                Snippet(trigger: "sig", expansion: "Best regards"),
                Snippet(trigger: "addr", expansion: "1 Example Street"),
            ]
            preferences.appStyleProfiles = [
                "com.example.Mail": StyleProfile(
                    name: "Mail",
                    tone: .professional,
                    structureMode: .email,
                    fillerPolicy: .minimal,
                    commandPolicy: .transform
                ),
                "com.example.Chat": StyleProfile(
                    name: "Chat",
                    tone: .friendly,
                    structureMode: .natural,
                    fillerPolicy: .balanced,
                    commandPolicy: .passthrough
                ),
            ]
            let data = try JSONEncoder().encode(preferences)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        @discardableResult
        func write(_ object: Any) throws -> Data {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: storageURL)
            return data
        }

        func filesContaining(_ original: Data) throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { (try? Data(contentsOf: $0)) == original }
        }

        func setDirectoryWritable(_ writable: Bool) {
            try? FileManager.default.setAttributes(
                [.posixPermissions: writable ? 0o755 : 0o555],
                ofItemAtPath: directory.path
            )
        }

        func cleanUp() {
            setDirectoryWritable(true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storageURL.path)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test("A file written by v0.1.10 keeps its vocabulary, shortcuts and settings")
    func legacyV0110FileLoads() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var legacy = LegacyV0110Preferences.default
        legacy.general.showOnboarding = false
        legacy.hotkeys.handsFreeGlobalKeyCode = 105
        legacy.lexiconEntries.append(LexiconEntry(term: "kube control", preferred: "kubectl", scope: .global))
        legacy.snippets = [Snippet(trigger: "sig", expansion: "Best regards")]
        try JSONEncoder().encode(legacy).write(to: fixture.storageURL)

        let store = fixture.store()
        let loaded = await store.load()
        #expect(loaded.lexiconEntries.map(\.preferred) == ["Steno", "StenoKit", "kubectl"])
        #expect(loaded.snippets.map(\.trigger) == ["sig"])
        #expect(loaded.general.showOnboarding == false)
        #expect(loaded.hotkeys.handsFreeGlobalKeyCode == 105)
        #expect(loaded.appearance == .legacy)
        #expect(await store.takeRecoveryNotices().isEmpty)

        #expect((try? await store.save(loaded).get()) != nil)
        let reloaded = await fixture.store().load()
        #expect(reloaded.lexiconEntries.map(\.preferred) == ["Steno", "StenoKit", "kubectl"])
        #expect(reloaded.snippets.map(\.trigger) == ["sig"])
    }

    @Test("Values from a newer version fall back without discarding the rest")
    func unknownValuesFallBack() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var object = try fixture.currentFormatObject()
        var appearance = try #require(object["appearance"] as? [String: Any])
        appearance["accent"] = "aurora"
        appearance["mode"] = "dim"
        object["appearance"] = appearance
        var insertion = try #require(object["insertion"] as? [String: Any])
        insertion["orderedMethods"] = ["direct", "dictationAPI", "clipboardPaste"]
        object["insertion"] = insertion
        var global = try #require(object["globalStyleProfile"] as? [String: Any])
        global["fillerPolicy"] = "extreme"
        global["tone"] = "poetic"
        object["globalStyleProfile"] = global
        var lexicon = try #require(object["lexiconEntries"] as? [[String: Any]])
        lexicon[2]["phoneticRecovery"] = "properNounEverywhere"
        object["lexiconEntries"] = lexicon
        let original = try fixture.write(object)

        let store = fixture.store()
        let loaded = await store.load()
        #expect(loaded.appearance.accent == .citron)
        #expect(loaded.appearance.mode == .dark)
        #expect(loaded.insertion.orderedMethods == [.direct, .clipboardPaste])
        #expect(loaded.globalStyleProfile.fillerPolicy == .balanced)
        #expect(loaded.globalStyleProfile.tone == .natural)
        #expect(loaded.globalStyleProfile.structureMode == .paragraph)
        #expect(loaded.lexiconEntries.count == 4)
        #expect(loaded.lexiconEntries[2].phoneticRecovery == .off)
        #expect(loaded.snippets.map(\.trigger) == ["sig", "addr"])
        #expect(loaded.hotkeys.handsFreeGlobalKeyCode == 105)
        #expect(loaded.general.showOnboarding == false)

        let notices = await store.takeRecoveryNotices()
        let kept = try #require(notices.first?.fileURL)
        #expect(try Data(contentsOf: kept) == original)
    }

    @Test("One unreadable correction, shortcut or app profile is skipped and kept in a copy")
    func badElementsAreSkipped() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var object = try fixture.currentFormatObject()
        var lexicon = try #require(object["lexiconEntries"] as? [[String: Any]])
        lexicon[3]["scope"] = ["window": ["title": "Notes"]]
        object["lexiconEntries"] = lexicon
        var snippets = try #require(object["snippets"] as? [[String: Any]])
        snippets[0].removeValue(forKey: "trigger")
        object["snippets"] = snippets
        var profiles = try #require(object["appStyleProfiles"] as? [String: Any])
        profiles["com.example.Notes"] = ["tone": "natural"]
        object["appStyleProfiles"] = profiles
        let original = try fixture.write(object)

        let store = fixture.store()
        let loaded = await store.load()
        #expect(loaded.lexiconEntries.map(\.preferred) == ["Steno", "StenoKit", "kubectl"])
        #expect(loaded.snippets.map(\.trigger) == ["addr"])
        #expect(Set(loaded.appStyleProfiles.keys) == ["com.example.Mail", "com.example.Chat"])

        let notices = await store.takeRecoveryNotices()
        #expect(notices.count == 1)
        #expect(notices.first?.message.hasPrefix("3 saved items") == true)

        #expect((try? await store.save(loaded).get()) != nil)
        #expect(!(try fixture.filesContaining(original)).isEmpty)
    }

    @Test("A missing section uses its defaults and leaves the others alone", arguments: [
        "appearance", "general", "hotkeys", "dictation", "insertion", "media",
        "lexiconEntries", "globalStyleProfile", "appStyleProfiles", "snippets",
    ])
    func missingSectionFallsBack(section: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var object = try fixture.currentFormatObject()
        object.removeValue(forKey: section)
        try fixture.write(object)

        let loaded = await fixture.store().load()
        if section != "lexiconEntries" {
            #expect(loaded.lexiconEntries.map(\.preferred).contains("kubectl"))
        }
        if section != "snippets" {
            #expect(loaded.snippets.map(\.trigger) == ["sig", "addr"])
        }
        if section != "hotkeys" {
            #expect(loaded.hotkeys.handsFreeGlobalKeyCode == 105)
        }
        if section != "appStyleProfiles" {
            #expect(loaded.appStyleProfiles.count == 2)
        }
    }

    @Test("A file that can't be read is moved aside, not overwritten", arguments: ["truncated", "array", "unreadable"])
    func unreadableFileIsMovedAside(damage: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let valid = try JSONSerialization.data(withJSONObject: try fixture.currentFormatObject())
        let original: Data
        switch damage {
        case "truncated": original = valid.dropLast(30)
        case "array": original = Data("[1, 2, 3]".utf8)
        default: original = valid
        }
        try original.write(to: fixture.storageURL)
        if damage == "unreadable" {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.storageURL.path)
        }

        let store = fixture.store()
        let loaded = await store.load()
        #expect(loaded == .default)
        #expect(await store.takeRecoveryNotices().count == 1)

        var edited = loaded
        edited.general.showOnboarding = false
        #expect((try? await store.save(edited).get()) != nil)

        let moved = try #require(await store.takeRecoveryNotices().first?.fileURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: moved.path)
        #expect(try Data(contentsOf: moved) == original)
        #expect(await fixture.store().load().general.showOnboarding == false)
    }

    @Test("Each successful save keeps the previous file")
    func saveKeepsPreviousCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        var first = AppPreferences.default
        first.snippets = [Snippet(trigger: "one", expansion: "First")]
        await store.save(first)
        var second = first
        second.snippets = []
        await store.save(second)

        let previous = try JSONDecoder().decode(
            AppPreferences.self,
            from: Data(contentsOf: StorageFilePreservation.previousCopyURL(for: fixture.storageURL))
        )
        #expect(previous.snippets.map(\.trigger) == ["one"])
    }

    @Test("A save that can't be written reports failure and leaves the file unchanged")
    func failedSaveReportsFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        await store.save(.default)
        let before = try Data(contentsOf: fixture.storageURL)

        var edited = AppPreferences.default
        edited.snippets = [Snippet(trigger: "lost", expansion: "Not saved")]
        fixture.setDirectoryWritable(false)
        let result = await store.save(edited)
        fixture.setDirectoryWritable(true)

        #expect(throws: AppPreferencesStoreError.self) { try result.get() }
        #expect(try Data(contentsOf: fixture.storageURL) == before)
    }

    @Test("Files written after recovery decode with the 1.0.0 types")
    func writtenFileLoadsInReleasedVersion() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var object = try fixture.currentFormatObject()
        var global = try #require(object["globalStyleProfile"] as? [String: Any])
        global["fillerPolicy"] = "extreme"
        object["globalStyleProfile"] = global
        var insertion = try #require(object["insertion"] as? [String: Any])
        insertion["orderedMethods"] = ["dictationAPI", "direct"]
        object["insertion"] = insertion
        var snippets = try #require(object["snippets"] as? [[String: Any]])
        snippets[1].removeValue(forKey: "scope")
        object["snippets"] = snippets
        object.removeValue(forKey: "media")
        try fixture.write(object)

        let store = fixture.store()
        var loaded = await store.load()
        loaded.hotkeys.handsFreeGlobalKeyCode = nil
        #expect((try? await store.save(loaded).get()) != nil)

        let released = try JSONDecoder().decode(
            Released100Preferences.Preferences.self,
            from: Data(contentsOf: fixture.storageURL)
        )
        #expect(released.lexiconEntries.count == 4)
        #expect(released.snippets.map(\.trigger) == ["sig", "addr"])
        #expect(released.globalStyleProfile.fillerPolicy == .balanced)
        #expect(released.appStyleProfiles.count == 2)
    }
}
