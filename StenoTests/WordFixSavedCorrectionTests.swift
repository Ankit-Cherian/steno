import Foundation
import StenoKit
import Testing
@testable import Steno

@MainActor
private final class SavedCorrectionHotkey: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16?

    func start() {}
    func stop() {}
}

/// Fixing a word for future dictations when the same Word Correction is already saved.
@Suite("Fix a Word keeps a saved Word Correction", .serialized)
@MainActor
struct WordFixSavedCorrectionTests {
    private static let saved = LexiconEntry(
        term: "Kubernetis", preferred: "Kubernetes", scope: .global,
        aliases: ["cooper netties"], phoneticRecovery: .properNounEnglish
    )

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoWordFixSaved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Fixing a word for future dictations leaves an identical saved Word Correction as configured (lexicon service)")
    func futureFixKeepsIdenticalCorrectionInTheLexiconService() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = HistoryStore(
            storageURL: directory.appendingPathComponent("history.json")
        )
        let entry = TranscriptEntry(
            appBundleID: "com.apple.Notes", rawText: "ask kubernetis about it",
            cleanText: "Ask Kubernetis about it.", audioURL: nil, insertionStatus: .inserted
        )
        try await history.append(entry: entry)
        let lexicon = PersonalLexiconService(entries: [Self.saved])
        try #require(await lexicon.snapshot().entries == [Self.saved], "probe: the service holds the saved correction")

        let fixed = try await history.applyWordFix(
            entryID: entry.id, original: "Kubernetis", occurrence: 0,
            replacement: "Kubernetes", appliesToFuture: true, lexicon: lexicon
        )

        #expect(fixed.cleanText == "Ask Kubernetes about it.")
        let after = await lexicon.snapshot().entries
        #expect(after == [Self.saved], "the saved correction came back as \(after)")
    }

    @Test("Fixing a word for future dictations leaves an identical saved Word Correction as configured (saved preferences)")
    func futureFixKeepsIdenticalCorrectionInPreferences() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferencesURL = directory.appendingPathComponent("preferences.json")
        let history = HistoryStore(
            storageURL: directory.appendingPathComponent("history.json")
        )
        let entry = TranscriptEntry(
            appBundleID: "com.apple.Notes", rawText: "ask kubernetis about it",
            cleanText: "Ask Kubernetis about it.", audioURL: nil, insertionStatus: .inserted
        )
        try await history.append(entry: entry)

        // The saved settings hold the correction, as Settings › Word Corrections would have written it.
        var seeded = AppPreferences.default
        seeded.lexiconEntries.append(Self.saved)
        let store = AppPreferencesStore(storageURL: preferencesURL)
        _ = await store.save(seeded)
        let reloaded = await AppPreferencesStore(storageURL: preferencesURL).load()
        try #require(reloaded.lexiconEntries.contains(Self.saved), "probe: the saved file holds the correction")

        let controller = makeTestDictationController(
            hotkey: SavedCorrectionHotkey(),
            preferencesStore: store,
            historyStore: history,
            legacyHistoryURL: directory.appendingPathComponent("legacy.json")
        )
        defer { controller.teardown() }
        controller.preferences = reloaded
        await controller.refreshHistory()
        try #require(controller.preferences.lexiconEntries.contains(Self.saved))

        let fixed = try await controller.applyWordFix(
            entryID: entry.id, original: "Kubernetis", occurrence: 0,
            replacement: "Kubernetes", appliesToFuture: true
        )
        #expect(fixed.cleanText == "Ask Kubernetes about it.")

        let live = controller.preferences.lexiconEntries.filter { $0.term == "Kubernetis" }
        #expect(live == [Self.saved], "Settings now holds \(live)")
        let persisted = await AppPreferencesStore(storageURL: preferencesURL).load()
            .lexiconEntries.filter { $0.term == "Kubernetis" }
        #expect(persisted == [Self.saved], "the file on disk holds \(persisted)")
    }
}
