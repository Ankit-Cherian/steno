import Foundation
import Testing
@testable import Steno
import StenoKit

private actor WarmRuntimeCoordinator: DictationSessionCoordinating {
    private(set) var unloadCount = 0
    private(set) var shutdownCount = 0

    func startPressToTalk(appContext: AppContext) async throws -> SessionID { SessionID() }
    func endPressToTalkCapture(sessionID: SessionID) async throws {}
    func completePressToTalk(sessionID: SessionID, languageHints: [String]) async throws -> InsertResult {
        InsertResult(status: .inserted, method: .direct, insertedText: "Hello")
    }
    func cancel(sessionID: SessionID) async {}
    func setHandsFreeEnabled(_ enabled: Bool) async {}
    func unloadTranscriptionRuntime() async { unloadCount += 1 }
    func shutdown() async { shutdownCount += 1 }
}

@MainActor
@Suite("Test setup")
struct SetupCheckControllerTests {
    @Test("The check reports each stage and leaves the warm runtime and History alone")
    func checkLeavesRuntimeAndHistoryAlone() async {
        let coordinator = WarmRuntimeCoordinator()
        let controller = makeTestDictationController(hotkey: CountingHotkeyService(), coordinator: coordinator)
        defer { controller.teardown() }
        var draft = controller.preferences
        draft.dictation.modelPath = "/nonexistent/ggml-medium.en.bin"

        let stages = await controller.runSetupCheck(preferences: draft)

        #expect(stages.map(\.title) == ["Microphone access", "Speech model", "Main engine", "Fallback tool"])
        #expect(stages[1].outcome == .failed)
        #expect(await coordinator.unloadCount == 0)
        #expect(await coordinator.shutdownCount == 0)
        await controller.refreshHistory()
        #expect(controller.recentEntries.isEmpty)
    }

    @Test("The check waits for a dictation in progress instead of competing with it")
    func checkRefusesDuringDictation() async {
        let controller = makeTestDictationController(
            hotkey: CountingHotkeyService(),
            coordinator: WarmRuntimeCoordinator()
        )
        defer { controller.teardown() }
        controller.pressToTalkStart()
        #expect(await waitForModelSetupCondition { controller.isRecording })

        let stages = await controller.runSetupCheck(preferences: controller.preferences)

        #expect(stages.count == 1)
        #expect(stages[0].outcome == .skipped)
        #expect(stages[0].detail == "Finish the current dictation, then try again.")
        #expect(controller.isRecording)
        controller.cancelActiveRecording()
    }
}
