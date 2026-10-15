import Foundation
import Testing
@testable import Steno
@testable import StenoKit

/// The window's Fix a word path, driven through the controller the window uses.
@Suite("Fix a word in the window", .serialized)
@MainActor
struct WordFixWiringTests {
    private final class Hotkey: HotkeyService {
        var onPressToTalkStart: (() -> Void)?
        var onPressToTalkStop: (() -> Void)?
        var onToggleHandsFree: (() -> Void)?
        var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
        var isOptionPressToTalkEnabled = true
        var globalToggleKeyCode: UInt16?
        func start() {}
        func stop() {}
    }

    @Test("A saved dictation is fixed and the fix undone through the controller, with the fix shown in its record")
    func applyThenUndo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoWordFix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = HistoryStore(
            storageURL: directory.appendingPathComponent("history.json")
        )
        let entry = TranscriptEntry(
            appBundleID: "com.example.steno-test-editor",
            rawText: "send it to dana tomorrow",
            cleanText: "Send it to Dana tomorrow.",
            audioURL: nil,
            insertionStatus: .inserted,
            record: DictationRecord(recordingMS: 2_000)
        )
        try await history.append(entry: entry)
        let controller = makeTestDictationController(
            hotkey: Hotkey(),
            preferencesStore: AppPreferencesStore(storageURL: directory.appendingPathComponent("preferences.json")),
            historyStore: history,
            usageAnalyticsStore: UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json")),
            legacyHistoryURL: directory.appendingPathComponent("legacy.json")
        )
        defer { controller.teardown() }
        await controller.refreshHistory()

        let fixer = WordFixers.current(for: controller)
        #expect(fixer.isAvailable)
        let range = (entry.cleanText as NSString).range(of: "Dana")
        let occurrence = try #require(DictationRecordBridge.occurrence(of: "Dana", in: range, text: entry.cleanText))

        let fixed = try await fixer.applyWordFix(
            entryID: entry.id, original: "Dana", occurrence: occurrence, replacement: "Danna",
            appliesToFuture: false, confirmingCommonWord: false
        )
        #expect(fixed.cleanText == "Send it to Danna tomorrow.")
        let shown = try #require(controller.recentEntries.first { $0.id == entry.id })
        #expect(shown.cleanText == "Send it to Danna tomorrow.")
        #expect(DictationRecordBridge.fixes(for: shown).map(\.replacement) == ["Danna"])
        #expect(DictationRecordBridge.record(for: shown)?.recordingMS == 2_000)

        let undone = try await fixer.undoLastWordFix(entryID: entry.id)
        #expect(undone.cleanText == "Send it to Dana tomorrow.")
        let restored = try #require(controller.recentEntries.first { $0.id == entry.id })
        #expect(DictationRecordBridge.fixes(for: restored).isEmpty)
    }

    @Test("In an isolated preview the sample dictation is fixed in memory only")
    func previewFixStaysInMemory() async throws {
        let controller = IsolatedAppPreview.makeController(populated: false)
        WindowSampleData.install(on: controller)
        let fixer = WordFixers.current(for: controller)
        #expect(fixer.isAvailable)

        let text = WindowSampleData.latestText
        let range = (text as NSString).range(of: "Dana")
        let occurrence = try #require(DictationRecordBridge.occurrence(of: "Dana", in: range, text: text))
        _ = try await fixer.applyWordFix(
            entryID: WindowSampleData.latestID, original: "Dana", occurrence: occurrence, replacement: "Danna",
            appliesToFuture: false, confirmingCommonWord: false
        )
        let fixed = try #require(controller.recentEntries.first { $0.id == WindowSampleData.latestID })
        #expect(fixed.cleanText.contains("Danna"))
        #expect(DictationRecordBridge.fixes(for: fixed).count == 1)
        _ = try await fixer.undoLastWordFix(entryID: WindowSampleData.latestID)
        let restored = try #require(controller.recentEntries.first { $0.id == WindowSampleData.latestID })
        #expect(restored.cleanText == text)
    }
}
