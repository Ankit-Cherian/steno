import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

// MARK: - Hands-free key registration status

@MainActor
@Test("A disabled hands-free key shows no error on save, permission refresh, or rebuild")
func disabledHandsFreeKeyShowsNoError() async {
    let presenter = makeShortcutTestPresenter()
    let hotkey = MacHotkeyMonitor()
    let controller = makeTestDictationController(hotkey: hotkey, overlay: presenter)
    defer { controller.teardown() }

    let rebuiltStatus = "Running local transcription + local cleanup."
    var draft = controller.preferences
    draft.hotkeys.handsFreeGlobalKeyCode = nil
    controller.applySettingsDraft(preferences: draft)
    #expect(await waitForShortcutCondition { controller.status == rebuiltStatus })
    controller.status = ""
    // Launch and "Check again" restart the monitor and reassign the key.
    controller.refreshPermissionStatuses()
    controller.savePreferences()
    #expect(await waitForShortcutCondition { controller.status == rebuiltStatus })

    #expect(controller.hotkeyRegistrationMessage.isEmpty)
    #expect(!presenter.hostedEvidenceShownStates().contains { $0.isFailure })
}

@MainActor
@Test("A hotkey registration failure during recording keeps Stop and Cancel")
func registrationFailureDuringRecordingKeepsControls() async {
    let events = ShortcutEventLog()
    let presenter = makeShortcutTestPresenter()
    let hotkey = StatusReportingHotkeyService()
    let controller = makeTestDictationController(
        hotkey: hotkey,
        overlay: presenter,
        coordinator: ShortcutTestCoordinator(events: events)
    )
    defer { controller.teardown() }

    controller.toggleHandsFree()
    #expect(await waitForShortcutCondition { presenter.hostedEvidenceShownStates().contains { $0.isListening } })

    hotkey.onRegistrationStatusChanged?(.unavailable(reason: "Accessibility permission required for global hotkey."))

    #expect(controller.hotkeyRegistrationMessage == "Accessibility permission required for global hotkey.")
    #expect(!presenter.hostedEvidenceShownStates().contains { $0.isFailure })
    #expect(presenter.hostedEvidenceStopIsAvailable())
    #expect(controller.recordingLifecycleState == .recordingHandsFree)

    hotkey.onRegistrationStatusChanged?(.disabled)
    #expect(controller.hotkeyRegistrationMessage.isEmpty)
}

// MARK: - Helpers

@MainActor
func makeShortcutTestPresenter() -> WaveformOverlayPresenter {
    let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
    presenter.hostedEvidencePrepareOffscreen()
    return presenter
}

extension OverlayState {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }

    var isListening: Bool {
        if case .listening = self { return true }
        return false
    }
}

actor ShortcutEventLog {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }

    func count(of event: String) -> Int {
        events.filter { $0 == event }.count
    }
}

actor ShortcutTestCoordinator: DictationSessionCoordinating {
    private let events: ShortcutEventLog
    private let transcript: String

    init(events: ShortcutEventLog, transcript: String = "Nearby words") {
        self.events = events
        self.transcript = transcript
    }

    func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        await events.append("capture.start")
        return SessionID()
    }

    func endPressToTalkCapture(sessionID: SessionID) async throws {
        await events.append("capture.stop")
    }

    func completePressToTalk(
        sessionID: SessionID,
        languageHints: [String]
    ) async throws -> InsertResult {
        // Insertion, History, and usage records are all written inside completion.
        await events.append("transcription.start")
        return InsertResult(status: .inserted, method: .accessibility, insertedText: transcript)
    }

    func cancel(sessionID: SessionID) async {
        await events.append("capture.cancel")
    }

    func setHandsFreeEnabled(_ enabled: Bool) async {}
}

@MainActor
final class ShortcutTestMediaService: MediaInterruptionService {
    private let events: ShortcutEventLog

    init(events: ShortcutEventLog) {
        self.events = events
    }

    func beginInterruption() async -> MediaInterruptionToken? {
        await events.append("media.pause")
        return MediaInterruptionToken()
    }

    func endInterruption(token: MediaInterruptionToken) async {
        await events.append("media.release")
    }
}

@MainActor
final class StatusReportingHotkeyService: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?

    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16?

    func start() {}
    func stop() {}
}

@MainActor
func waitForShortcutCondition(
    attempts: Int = 400,
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}
