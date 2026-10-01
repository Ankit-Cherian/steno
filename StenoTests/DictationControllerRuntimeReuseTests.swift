import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

@Suite(.serialized)
@MainActor
struct DictationControllerRuntimeReuseTests {
    @Test("Saving settings that don't affect transcription keeps the loaded engine")
    func unrelatedSaveKeepsEngine() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoRuntimeReuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engines = EngineBuildLog()
        let clipboard = MemoryClipboardService()
        let controller = DictationController(
            hotkey: TranscriptionCancelHotkey(),
            clipboardService: clipboard,
            overlay: WaveformOverlayPresenter(observeAccessibilityChanges: false),
            mediaInterruption: IsolatedTestMediaService(),
            preferencesStore: AppPreferencesStore(storageURL: directory.appendingPathComponent("preferences.json")),
            transcriptionEngineFactory: { settings in engines.build(settings) },
            historyStore: HistoryStore(storageURL: directory.appendingPathComponent("history.json"), clipboardService: clipboard),
            usageAnalyticsStore: UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json")),
            legacyHistoryURL: directory.appendingPathComponent("legacy.json"),
            systemIntegrationsEnabled: false
        )

        var draft = controller.preferences
        #expect(await controller.applySettingsDraft(preferences: draft).value)
        #expect(engines.built.count == 1)

        // A snippet, a vocabulary correction and the insertion order change
        // what the coordinator does, not the engine.
        draft.snippets.append(Snippet(trigger: "sig", expansion: "Best regards"))
        #expect(await controller.applySettingsDraft(preferences: draft).value)
        draft.lexiconEntries.append(LexiconEntry(term: "steno kit", preferred: "StenoKit", scope: .global))
        #expect(await controller.applySettingsDraft(preferences: draft).value)
        draft.insertion.orderedMethods.reverse()
        #expect(await controller.applySettingsDraft(preferences: draft).value)

        #expect(engines.built.count == 1)
        #expect(await engines.built[0].shutdowns == 0)
        #expect(await engines.built[0].unloads == 0)

        // A change the engine depends on replaces it once.
        draft = controller.preferences
        draft.dictation.threadCount += 1
        #expect(await controller.applySettingsDraft(preferences: draft).value)
        #expect(engines.built.count == 2)
        #expect(await engines.built[0].shutdowns == 1)
        #expect(await engines.built[1].shutdowns == 0)
        #expect(engines.settings[1].threadCount == engines.settings[0].threadCount + 1)

        await controller.teardownAndWait()
        #expect(await engines.built[1].shutdowns == 1)
    }
}

@MainActor
final class EngineBuildLog {
    private(set) var built: [CountingShutdownEngine] = []
    private(set) var settings: [TranscriptionEngineSettings] = []

    func build(_ settings: TranscriptionEngineSettings) -> any TranscriptionEngine {
        let engine = CountingShutdownEngine()
        built.append(engine)
        self.settings.append(settings)
        return engine
    }
}

actor CountingShutdownEngine: TranscriptionEngine {
    private(set) var shutdowns = 0
    private(set) var unloads = 0

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        RawTranscript(text: "Reused engine.")
    }

    func shutdown() async { shutdowns += 1 }
    func unloadRetainedResources() async { unloads += 1 }
}
