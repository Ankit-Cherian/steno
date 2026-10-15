import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

/// A coordinator whose runtime unload stays open until the test opens its gate,
/// and that records every capture start so a refused press can be shown to have
/// started nothing.
actor UnloadGatedCoordinator: DictationSessionCoordinating {
    private let unloadGate = ShortcutGate()
    private(set) var unloadStarted = false
    private(set) var captureStarts = 0

    func openUnload() async { await unloadGate.open() }

    func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        captureStarts += 1
        return SessionID()
    }

    func endPressToTalkCapture(sessionID: SessionID) async throws {}

    func completePressToTalk(sessionID: SessionID, languageHints: [String]) async throws -> InsertResult {
        InsertResult(status: .noSpeech, method: .none, insertedText: "")
    }

    func cancel(sessionID: SessionID) async {}
    func setHandsFreeEnabled(_ enabled: Bool) async {}

    func unloadTranscriptionRuntime() async {
        unloadStarted = true
        await unloadGate.wait()
    }
}

@MainActor
private func makeUnloadingController(
    hotkey: FilteringHotkeyService,
    presenter: WaveformOverlayPresenter,
    coordinator: UnloadGatedCoordinator,
    center: NotificationCenter
) async -> DictationController {
    let controller = makeTestDictationController(
        hotkey: hotkey,
        overlay: presenter,
        coordinator: coordinator,
        workspaceNotificationCenter: center
    )
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    #expect(await waitForShortcutCondition { await coordinator.unloadStarted })
    return controller
}

@MainActor
@Test("An Option hold during a system runtime unload shows why nothing is recording and starts no capture")
func optionHoldDuringRuntimeUnloadShowsTheBusyLine() async {
    let center = NotificationCenter()
    let presenter = makeShortcutTestPresenter()
    let hotkey = FilteringHotkeyService()
    let coordinator = UnloadGatedCoordinator()
    let controller = await makeUnloadingController(
        hotkey: hotkey, presenter: presenter, coordinator: coordinator, center: center
    )
    defer { controller.teardown() }

    hotkey.press([.option])
    try? await Task.sleep(for: .milliseconds(50))
    // Until the press proves to be a dictation, nothing is shown.
    #expect(presenter.hostedEvidenceRequestedStates().isEmpty)

    hotkey.holdPastConfirmationWindow()
    #expect(await waitForShortcutCondition {
        presenter.hostedEvidenceRequestedStates() == [.busy(.modelLoading)]
    })
    #expect(presenter.hostedEvidenceUserFacingStrings().contains("Still loading the speech model"))
    #expect(controller.status == "Runtime is releasing memory. Try again in a moment.")
    #expect(controller.recordingLifecycleState == .idle)
    #expect(await coordinator.captureStarts == 0)

    hotkey.press([], after: 1)
    await coordinator.openUnload()
    #expect(await coordinator.captureStarts == 0)
}

@MainActor
@Test("The hands-free key during a system runtime unload shows the busy line at once and starts no capture")
func handsFreeDuringRuntimeUnloadShowsTheBusyLine() async {
    let center = NotificationCenter()
    let presenter = makeShortcutTestPresenter()
    let hotkey = FilteringHotkeyService()
    let coordinator = UnloadGatedCoordinator()
    let controller = await makeUnloadingController(
        hotkey: hotkey, presenter: presenter, coordinator: coordinator, center: center
    )
    defer { controller.teardown() }

    controller.toggleHandsFree()

    #expect(await waitForShortcutCondition {
        presenter.hostedEvidenceRequestedStates() == [.busy(.modelLoading)]
    })
    #expect(controller.recordingLifecycleState == .idle)
    #expect(await coordinator.captureStarts == 0)
    await coordinator.openUnload()
}

@MainActor
@Test("An Option keyboard shortcut during a system runtime unload stays silent")
func optionShortcutDuringRuntimeUnloadStaysSilent() async {
    let center = NotificationCenter()
    let presenter = makeShortcutTestPresenter()
    let hotkey = FilteringHotkeyService()
    let coordinator = UnloadGatedCoordinator()
    let controller = await makeUnloadingController(
        hotkey: hotkey, presenter: presenter, coordinator: coordinator, center: center
    )
    defer { controller.teardown() }

    hotkey.press([.option])
    hotkey.keyDown(after: 0.05)
    hotkey.press([], after: 0.05)
    try? await Task.sleep(for: .milliseconds(100))

    #expect(presenter.hostedEvidenceRequestedStates().isEmpty)
    await coordinator.openUnload()
}
