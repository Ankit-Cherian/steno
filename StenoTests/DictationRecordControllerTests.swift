import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

@MainActor
private final class RecordTestHotkeyService: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16?

    func start() {}
    func stop() {}
}

private struct SlowTextEngine: TranscriptionEngine {
    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        try await Task.sleep(for: .milliseconds(50))
        return RawTranscript(text: "ship the deck to stenoh", durationMS: 1_200)
    }
}

@Suite("Dictation record and Fix a word in the app", .serialized)
@MainActor
struct DictationRecordControllerTests {
    private struct Fixture {
        let directory: URL
        let history: HistoryStore
        let clipboard = MemoryClipboardService()
        let preferencesURL: URL
        let usageURL: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("StenoRecord-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            history = HistoryStore(storageURL: directory.appendingPathComponent("history.json"))
            preferencesURL = directory.appendingPathComponent("preferences.json")
            usageURL = directory.appendingPathComponent("usage.json")
        }

        @MainActor
        func controller(coordinator: (any DictationSessionCoordinating)? = nil, overlay: WaveformOverlayPresenter? = nil) -> DictationController {
            makeTestDictationController(
                hotkey: RecordTestHotkeyService(),
                overlay: overlay ?? WaveformOverlayPresenter(observeAccessibilityChanges: false),
                preferencesStore: AppPreferencesStore(storageURL: preferencesURL),
                coordinator: coordinator,
                historyStore: history,
                usageAnalyticsStore: UsageAnalyticsStore(storageURL: usageURL),
                legacyHistoryURL: directory.appendingPathComponent("legacy.json"),
                clipboardService: clipboard
            )
        }

        /// Everything the Insights ledger wrote, as text.
        func insightsFiles() -> String {
            let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
            var text = ""
            while let url = enumerator?.nextObject() as? URL {
                guard url.path.contains("/usage") else { continue }
                text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
            return text
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    @Test("A dictation through the isolated pipeline saves its record with every step timed")
    func endToEndRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let capture = TranscriptionCancelCapture(directory: fixture.directory)
        let transport = TranscriptionCancelTransport()
        let coordinator = SessionCoordinator(
            captureService: capture,
            transcriptionEngine: SlowTextEngine(),
            cleanupEngine: RuleBasedCleanupEngine(),
            insertionService: InsertionService(transports: [transport]),
            historyStore: fixture.history,
            lexiconService: PersonalLexiconService(entries: AppPreferences.default.lexiconEntries),
            styleProfileService: StyleProfileService(),
            recordSettings: DictationController.recordSettings(for: AppPreferences.default),
            editorTargetCapture: { _ in .failure(.unsupportedElement) }
        )
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.hostedEvidencePrepareOffscreen()
        let controller = fixture.controller(coordinator: coordinator, overlay: presenter)
        defer { controller.teardown() }

        controller.pressToTalkStart()
        try #require(await cancelTestEventually { await capture.startedCount() == 1 })
        try await Task.sleep(for: .milliseconds(30))
        controller.pressToTalkStop()
        try #require(await cancelTestEventually { await transport.texts().count == 1 })
        try #require(await cancelTestEventually { await MainActor.run { controller.recentEntries.first?.record != nil } })

        let entry = try #require(controller.recentEntries.first)
        let record = try #require(entry.record)
        #expect(entry.cleanText == "Ship the deck to Steno")
        #expect((record.recordingMS ?? -1) >= 0)
        #expect((record.transcriptionMS ?? 0) >= 50)
        #expect(record.cleanupMS != nil)
        #expect(record.insertionMS != nil)
        let expectedSettings = DictationController.recordSettings(for: AppPreferences.default)
        #expect(record.modelName == expectedSettings.modelName)
        #expect(record.modelID == expectedSettings.modelID)
        #expect(record.vadEnabled == true)
        #expect(record.schemaVersion == 1)
        #expect(record.attemptID != nil)
        #expect(record.outcome == "inserted")
        #expect((record.endToEndMS ?? 0) >= 50)
        #expect(record.language == "en-US")
        #expect(record.cleanupStyle != nil)
        #expect(record.appName == "Test Editor")
        #expect(record.appBundleID == "com.example.steno-test-editor")
        #expect(record.insertionMethod != nil)
        #expect(record.cleanupChanges?.contains(CleanupChangeRecord(kind: "replaced", before: "stenoh", after: "Steno")) == true)
        // Nothing from the editor or the audio is kept.
        let saved = try String(contentsOf: fixture.directory.appendingPathComponent("history.json"), encoding: .utf8)
        #expect(!saved.contains("Fixture document"))
        #expect(!saved.contains(".wav"))
        await coordinator.shutdown()
    }

    @Test("The speech model's display name and identifier come from the model file")
    func modelDisplayNames() {
        var preferences = AppPreferences.default
        preferences.dictation.modelPath = "/a/ggml-medium.en.bin"
        preferences.dictation.vadEnabled = false
        #expect(DictationController.recordSettings(for: preferences) == DictationRecordSettings(
            modelName: "Medium", modelID: "ggml-medium.en", vadEnabled: false
        ))
        #expect(DictationController.modelDisplayName(forModelPath: "/a/ggml-small.en.bin") == "Small")
        #expect(DictationController.modelDisplayName(forModelPath: "/a/ggml-large-v3-turbo.bin") == "Large V3 Turbo")
        #expect(DictationController.modelDisplayName(forModelPath: "/a/my-custom-model.bin") == "my-custom-model")
        #expect(DictationController.modelDisplayName(forModelPath: "") == nil)
    }

    @Test("Fix a word changes this dictation, undoes, copies the corrected text and leaves Insights alone")
    func fixUndoAndCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let entry = TranscriptEntry(
            appBundleID: "com.apple.Notes",
            rawText: "send it to sam and sam",
            cleanText: "Send it to Sam and Sam",
            audioURL: nil,
            insertionStatus: .inserted
        )
        try await fixture.history.append(entry: entry)
        let controller = fixture.controller()
        defer { controller.teardown() }
        await controller.refreshHistory()
        let insightsBefore = fixture.insightsFiles()

        let fixed = try await controller.applyWordFix(entryID: entry.id, original: "Sam", occurrence: 1, replacement: "Pam", appliesToFuture: false)
        #expect(fixed.cleanText == "Send it to Sam and Pam")
        #expect(controller.recentEntries.first?.cleanText == "Send it to Sam and Pam")
        #expect(controller.preferences.lexiconEntries == AppPreferences.default.lexiconEntries)

        await controller.copyCorrectedText(entryID: entry.id)
        #expect(await fixture.clipboard.latestValue == "Send it to Sam and Pam")

        let undone = try await controller.undoLastWordFix(entryID: entry.id)
        #expect(undone.cleanText == "Send it to Sam and Sam")
        #expect(controller.recentEntries.first?.fixes == nil)

        #expect(fixture.insightsFiles() == insightsBefore)
        #expect(!fixture.insightsFiles().contains("Pam"))
    }

    @Test("Fixing a word in every dictation saves a word correction; a common word asks first")
    func futureFixSavesCorrection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let entry = TranscriptEntry(
            appBundleID: "com.apple.Notes",
            rawText: "ask kubernetis about the plan",
            cleanText: "Ask Kubernetis about the plan",
            audioURL: nil,
            insertionStatus: .inserted
        )
        try await fixture.history.append(entry: entry)
        let controller = fixture.controller()
        defer { controller.teardown() }
        await controller.refreshHistory()

        // The app and this bundle each link StenoKit, so the error is matched by its message.
        await #expect {
            try await controller.applyWordFix(entryID: entry.id, original: "the", occurrence: 0, replacement: "a", appliesToFuture: true)
        } throws: { error in
            error.localizedDescription == "\u{201C}the\u{201D} is a common word. Fix it in this and future dictations?"
        }
        #expect(controller.recentEntries.first?.cleanText == "Ask Kubernetis about the plan")
        #expect(!controller.preferences.lexiconEntries.contains { $0.term == "the" })

        let fixed = try await controller.applyWordFix(entryID: entry.id, original: "Kubernetis", occurrence: 0, replacement: "Kubernetes", appliesToFuture: true)
        #expect(fixed.cleanText == "Ask Kubernetes about the plan")
        let correction = LexiconEntry(term: "Kubernetis", preferred: "Kubernetes", scope: .global)
        #expect(controller.preferences.lexiconEntries.contains(correction))
        let saved = await AppPreferencesStore(storageURL: fixture.preferencesURL).load()
        #expect(saved.lexiconEntries.contains(correction))

        let confirmed = try await controller.applyWordFix(
            entryID: entry.id, original: "the", occurrence: 0, replacement: "a",
            appliesToFuture: true, confirmingCommonWord: true
        )
        #expect(confirmed.cleanText == "Ask Kubernetes about a plan")

        // A fix at the start of a sentence is saved in the casing the word has mid-sentence.
        let startEntry = TranscriptEntry(
            appBundleID: "com.apple.Notes",
            rawText: "teh plan",
            cleanText: "Teh plan",
            audioURL: nil,
            insertionStatus: .inserted
        )
        try await fixture.history.append(entry: startEntry)
        _ = try await controller.applyWordFix(entryID: startEntry.id, original: "Teh", occurrence: 0, replacement: "The", appliesToFuture: true)
        #expect(controller.preferences.lexiconEntries.contains(LexiconEntry(term: "teh", preferred: "the", scope: .global)))
        #expect(!controller.preferences.lexiconEntries.contains { $0.preferred == "The" })
        #expect(controller.preferences.lexiconEntries.contains(LexiconEntry(term: "the", preferred: "a", scope: .global)))
    }
}
