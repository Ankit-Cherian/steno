import Foundation
import Testing
@testable import Steno
@testable import StenoKit

/// Review settings on the Dictate tab opens the page that fixes the last error.

@MainActor
private func makeRoutingController(
    coordinator: (any DictationSessionCoordinating)? = nil,
    preferencesStore: AppPreferencesStore? = nil
) -> DictationController {
    let controller = makeTestDictationController(
        hotkey: StatusReportingHotkeyService(),
        overlay: makeShortcutTestPresenter(),
        preferencesStore: preferencesStore,
        coordinator: coordinator
    )
    controller.microphonePermissionStatus = .granted
    controller.accessibilityPermissionStatus = .granted
    controller.inputMonitoringPermissionStatus = .granted
    return controller
}

@MainActor
private func dictateOnce(with controller: DictationController) async {
    controller.toggleHandsFree()
    #expect(await waitForShortcutCondition { controller.isRecording })
    controller.toggleHandsFree()
    #expect(await waitForShortcutCondition { controller.recordingLifecycleState == .idle })
}

@MainActor
@Test("An insertion failure sends Review settings to Text output, or to Permissions without Accessibility")
func insertionFailureRoutesToTextOutput() async {
    let reason = "The editor closed before insertion."
    let controller = makeRoutingController(coordinator: CaptureTestCoordinator(
        result: InsertResult(status: .failed, method: .none, insertedText: "Fictional words", errorMessage: reason)
    ))
    defer { controller.teardown() }

    await dictateOnce(with: controller)

    #expect(controller.lastError == reason)
    #expect(controller.recoverySection == .output)
    controller.accessibilityPermissionStatus = .denied
    #expect(controller.recoverySection == .permissions)
}

@MainActor
@Test("A transcript copied instead of inserted sends Review settings to Text output")
func copiedOnlyReasonRoutesToTextOutput() async {
    let reason = "Focus moved to a different field while Steno was transcribing."
    let controller = makeRoutingController(coordinator: CaptureTestCoordinator(
        result: InsertResult(status: .copiedOnly, method: .none, insertedText: "Fictional words", errorMessage: reason)
    ))
    defer { controller.teardown() }

    await dictateOnce(with: controller)

    #expect(controller.lastError == reason)
    #expect(controller.recoverySection == .output)
}

@MainActor
@Test("A transcription failure sends Review settings to Speech model")
func transcriptionFailureRoutesToSpeechModel() async {
    let controller = makeRoutingController(coordinator: FailingTranscriptionCoordinator())
    defer { controller.teardown() }

    await dictateOnce(with: controller)

    #expect(controller.status == "Transcription failed")
    #expect(controller.lastError == LiveTranscriptionFinalizationError.authoritativeFallbackExhausted.localizedDescription)
    #expect(controller.recoverySection == .engine)
}

@MainActor
@Test("A settings save that fails sends Review settings to the page it was saved from")
func failedSaveRoutesToSavedPage() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoRecoveryRouting-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    let store = AppPreferencesStore(storageURL: directory.appendingPathComponent("preferences.json"))
    await store.save(.default)
    let controller = makeRoutingController(preferencesStore: store)
    defer { controller.teardown() }
    var draft = controller.preferences
    draft.snippets = [Snippet(trigger: "sig", expansion: "Best regards")]

    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    #expect(await controller.applySettingsDraft(preferences: draft, savedFrom: .shortcuts).value == false)

    #expect(controller.status == "Settings couldn't be saved.")
    #expect(controller.lastError == controller.settingsSaveError)
    #expect(controller.recoverySection == .shortcuts)
}

private actor FailingTranscriptionCoordinator: DictationSessionCoordinating {
    func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        SessionID()
    }

    func endPressToTalkCapture(sessionID: SessionID) async throws {}

    func completePressToTalk(sessionID: SessionID, languageHints: [String]) async throws -> InsertResult {
        throw LiveTranscriptionFinalizationError.authoritativeFallbackExhausted
    }

    func cancel(sessionID: SessionID) async {}

    func setHandsFreeEnabled(_ enabled: Bool) async {}
}
