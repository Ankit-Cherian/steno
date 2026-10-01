import Foundation
import Testing
@testable import Steno
import StenoKit

@MainActor
@Suite("Setup messages")
struct SetupMessagesTests {
    @Test("Startup warnings name the Speech model page")
    func startupWarningsNameSpeechModel() {
        #expect(DictationController.startupPathWarning(cliExists: true, modelExists: true) == nil)
        for (cli, model) in [(false, false), (false, true), (true, false)] {
            let warning = DictationController.startupPathWarning(cliExists: cli, modelExists: model)
            #expect(warning?.hasSuffix("Check Settings \u{2192} Speech model.") == true)
            #expect(warning?.contains("Engine") == false)
        }
    }

    @Test("The voice-detection hint gives a plain instruction, never a shell command")
    func vadHintIsPlain() {
        let missing = EngineSettingsSection.vadModelPathMessage(path: "/gone/vad.bin", fileExists: { _ in false }, includedModelAvailable: true)
        let empty = EngineSettingsSection.vadModelPathMessage(path: "", fileExists: { _ in false }, includedModelAvailable: false)
        #expect(missing?.contains("use the included one") == true)
        #expect(empty?.contains("turn off voice activity detection") == true)
        for message in [missing, empty].compactMap({ $0 }) {
            #expect(!message.contains("./"))
            #expect(!message.contains(".sh"))
        }
        #expect(EngineSettingsSection.vadModelPathMessage(path: "/vad.bin", fileExists: { _ in true }, includedModelAvailable: true) == nil)
    }
}

@MainActor
@Test("A missing model at launch stays reported after the runtime starts")
func startupWarningSurvivesRuntimeRebuild() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoStartupWarning-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AppPreferencesStore(storageURL: directory.appendingPathComponent("preferences.json"))
    var saved = AppPreferences.default
    saved.general.showOnboarding = false
    saved.dictation.whisperCLIPath = "/nonexistent/bin/whisper-cli"
    saved.dictation.updateModelPath("/nonexistent/models/ggml-small.en.bin")
    await store.save(saved)

    let controller = makeTestDictationController(hotkey: CountingHotkeyService(), preferencesStore: store)
    defer { controller.teardown() }
    await controller.bootstrap()

    try #require(!FileManager.default.fileExists(atPath: controller.preferences.dictation.modelPath),
                 "this check needs a host without a bundled or development runtime")
    #expect(controller.status.hasSuffix("Check Settings \u{2192} Speech model."))
}
