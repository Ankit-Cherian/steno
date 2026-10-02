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
        // Applying the settings doesn't replace the save confirmation.
        #expect(controller.status == "Settings saved.")

        // A change the engine depends on replaces it once.
        draft = controller.preferences
        draft.dictation.threadCount += 1
        #expect(await controller.applySettingsDraft(preferences: draft).value)
        #expect(engines.built.count == 2)
        #expect(await engines.built[0].shutdowns == 1)
        #expect(await engines.built[1].shutdowns == 0)
        #expect(engines.settings[1].threadCount == engines.settings[0].threadCount + 1)
        #expect(controller.status == "Settings saved.")

        await controller.teardownAndWait()
        #expect(await engines.built[1].shutdowns == 1)
    }

    @Test("Saving a change to only the model path loads the new model, and saving again does not")
    func modelPathChangeReplacesEngine() async throws {
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

        let otherModel = directory.appendingPathComponent("ggml-base.en.bin")
        try Data("fictional model".utf8).write(to: otherModel)
        draft = controller.preferences
        draft.dictation.modelPath = otherModel.path
        draft.dictation.vadModelPath = controller.preferences.dictation.vadModelPath
        #expect(await controller.applySettingsDraft(preferences: draft).value)

        #expect(engines.built.count == 2)
        #expect(engines.settings.last?.modelPath == controller.preferences.dictation.modelPath)
        #expect(engines.settings.last?.modelPath != engines.settings.first?.modelPath)
        #expect(await engines.built[0].shutdowns == 1)

        // Saving the same settings again keeps the newly loaded engine.
        #expect(await controller.applySettingsDraft(preferences: controller.preferences).value)
        #expect(engines.built.count == 2)
        #expect(await engines.built[1].shutdowns == 0)

        await controller.teardownAndWait()
    }
}

extension DictationControllerRuntimeReuseTests {
    @Test("A model file replaced at the same path, such as one downloaded again, loads a new engine once")
    func replacedModelFileReplacesEngine() async throws {
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

        let model = directory.appendingPathComponent("ggml-base.en.bin")
        let vadModel = directory.appendingPathComponent("ggml-silero-v6.2.0.bin")
        try Data("fictional damaged model".utf8).write(to: model)
        try Data("fictional voice detection".utf8).write(to: vadModel)
        var draft = controller.preferences
        draft.dictation.modelPath = model.path
        draft.dictation.vadModelPath = vadModel.path
        #expect(await controller.applySettingsDraft(preferences: draft).value)
        #expect(engines.built.count == 1)
        #expect(controller.preferences.dictation.modelPath == model.path)
        #expect(controller.preferences.dictation.vadModelPath == vadModel.path)

        // An unchanged file keeps the loaded engine.
        #expect(await controller.applySettingsDraft(preferences: controller.preferences).value)
        #expect(engines.built.count == 1)

        // Downloading the model again replaces the file at the same path.
        try Data("fictional repaired model, a different size".utf8).write(to: model, options: .atomic)
        #expect(await controller.applySettingsDraft(preferences: controller.preferences).value)
        #expect(engines.built.count == 2)
        #expect(await engines.built[0].shutdowns == 1)
        #expect(engines.settings[1].modelPath == engines.settings[0].modelPath)

        #expect(await controller.applySettingsDraft(preferences: controller.preferences).value)
        #expect(engines.built.count == 2)

        // So does replacing the voice-detection model.
        try Data("fictional voice detection, replaced".utf8).write(to: vadModel, options: .atomic)
        #expect(await controller.applySettingsDraft(preferences: controller.preferences).value)
        #expect(engines.built.count == 3)
        #expect(await engines.built[1].shutdowns == 1)
        #expect(await engines.built[2].shutdowns == 0)

        await controller.teardownAndWait()
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
