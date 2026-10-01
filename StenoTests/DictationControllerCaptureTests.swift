import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

// MARK: - A recording the microphone cut short

@MainActor
@Test("A recording cut short with no speech says the microphone stopped, not no speech")
func stoppedMicrophoneWithoutSpeechShowsMicrophoneMessage() async {
    let warning = CaptureInterruption(reason: .recorderStopped, deviceName: "USB Desk Mic").message
    var result = InsertResult(status: .noSpeech, method: .none, insertedText: "")
    result.captureWarning = warning
    let presenter = makeShortcutTestPresenter()
    let coordinator = CaptureTestCoordinator(result: result)
    let controller = makeTestDictationController(
        hotkey: StatusReportingHotkeyService(),
        overlay: presenter,
        coordinator: coordinator
    )
    defer { controller.teardown() }

    controller.toggleHandsFree()
    #expect(await waitForShortcutCondition { controller.isRecording })
    controller.toggleHandsFree()
    #expect(await waitForShortcutCondition { controller.recordingLifecycleState == .idle })

    #expect(controller.status == "Microphone stopped.")
    #expect(controller.lastError == warning)
    #expect(presenter.hostedEvidenceShownStates().last == .failure(message: warning))
    #expect(!presenter.hostedEvidenceShownStates().contains(.noSpeechDetected))
}

@MainActor
@Test("Text from a recording cut short is inserted, and the microphone message is shown")
func stoppedMicrophoneWithTextInsertsAndWarns() async {
    let warning = CaptureInterruption(reason: .recorderStopped).message
    var result = InsertResult(status: .inserted, method: .accessibility, insertedText: "Send the report")
    result.captureWarning = warning
    let presenter = makeShortcutTestPresenter()
    let controller = makeTestDictationController(
        hotkey: StatusReportingHotkeyService(),
        overlay: presenter,
        coordinator: CaptureTestCoordinator(result: result)
    )
    defer { controller.teardown() }

    controller.toggleHandsFree()
    #expect(await waitForShortcutCondition { controller.isRecording })
    controller.toggleHandsFree()
    #expect(await waitForShortcutCondition { controller.recordingLifecycleState == .idle })

    #expect(controller.lastTranscript == "Send the report")
    #expect(controller.status == "Transcript inserted. Microphone stopped early.")
    #expect(controller.lastError == warning)
    #expect(presenter.hostedEvidenceShownStates().last == .failure(message: warning))
}

@MainActor
@Test("A recorder that stops by itself ends the session so its audio is transcribed")
func recorderStoppingEndsSession() async {
    let coordinator = CaptureTestCoordinator(
        result: InsertResult(status: .inserted, method: .accessibility, insertedText: "Kept words")
    )
    let controller = makeTestDictationController(
        hotkey: StatusReportingHotkeyService(),
        overlay: makeShortcutTestPresenter(),
        coordinator: coordinator
    )
    defer { controller.teardown() }

    controller.toggleHandsFree()
    #expect(await waitForShortcutCondition { controller.isRecording })

    // A stale session's callback changes nothing.
    controller.recorderStoppedEarly(sessionID: SessionID())
    #expect(controller.isRecording)

    let sessionID = await coordinator.startedSessionIDs.last!
    controller.recorderStoppedEarly(sessionID: sessionID)
    #expect(await waitForShortcutCondition { controller.lastTranscript == "Kept words" })
    let events = await coordinator.events
    #expect(events.contains("complete"))
    #expect(!events.contains("cancel"))
    #expect(await waitForShortcutCondition { controller.recordingLifecycleState == .idle })
}

// MARK: - Microphone access

private let microphoneOffMessage = "Microphone access is off. Turn it on for Steno in System Settings > Privacy & Security > Microphone."

@MainActor
@Test("With microphone access denied, the hands-free key starts nothing and says why")
func deniedMicrophoneBlocksHandsFree() async {
    let presenter = makeShortcutTestPresenter()
    let coordinator = CaptureTestCoordinator(
        result: InsertResult(status: .inserted, method: .accessibility, insertedText: "unused")
    )
    let controller = makeTestDictationController(
        hotkey: StatusReportingHotkeyService(),
        overlay: presenter,
        coordinator: coordinator
    )
    defer { controller.teardown() }
    controller.microphoneAccessProvider = { .denied }

    controller.toggleHandsFree()
    try? await Task.sleep(for: .milliseconds(50))

    #expect(await coordinator.events.isEmpty)
    #expect(controller.recordingLifecycleState == .idle)
    #expect(!controller.isRecording)
    #expect(controller.status == "Microphone access is off.")
    #expect(controller.lastError == microphoneOffMessage)
    #expect(controller.microphonePermissionStatus == .denied)
    #expect(presenter.hostedEvidenceShownStates() == [.failure(message: microphoneOffMessage)])

    // Once access is back, the same key records.
    controller.microphoneAccessProvider = { .granted }
    controller.toggleHandsFree()
    #expect(await waitForShortcutCondition { controller.isRecording })
}

@MainActor
@Test("With microphone access denied, holding Option starts nothing and shows the microphone message")
func deniedMicrophoneBlocksOptionHold() async {
    let presenter = makeShortcutTestPresenter()
    let hotkey = FilteringHotkeyService()
    let coordinator = CaptureTestCoordinator(
        result: InsertResult(status: .inserted, method: .accessibility, insertedText: "unused")
    )
    let controller = makeTestDictationController(hotkey: hotkey, overlay: presenter, coordinator: coordinator)
    defer { controller.teardown() }
    controller.microphoneAccessProvider = { .denied }

    hotkey.press([.option])
    try? await Task.sleep(for: .milliseconds(50))
    // Until the press proves to be a dictation, nothing is shown.
    #expect(presenter.hostedEvidenceShownStates().isEmpty)

    hotkey.holdPastConfirmationWindow()
    #expect(await waitForShortcutCondition {
        presenter.hostedEvidenceShownStates() == [.failure(message: microphoneOffMessage)]
    })
    hotkey.press([], after: 1)

    #expect(await coordinator.events.isEmpty)
    #expect(controller.recordingLifecycleState == .idle)
    #expect(controller.lastError == microphoneOffMessage)
}

@MainActor
@Test("With microphone access denied, an Option keyboard shortcut still leaves no trace")
func deniedMicrophoneKeepsOptionShortcutsSilent() async {
    let presenter = makeShortcutTestPresenter()
    let hotkey = FilteringHotkeyService()
    let coordinator = CaptureTestCoordinator(
        result: InsertResult(status: .inserted, method: .accessibility, insertedText: "unused")
    )
    let controller = makeTestDictationController(hotkey: hotkey, overlay: presenter, coordinator: coordinator)
    defer { controller.teardown() }
    controller.microphoneAccessProvider = { .denied }
    controller.status = "Ready"

    hotkey.press([.option])
    hotkey.keyDown(after: 0.05)
    hotkey.press([], after: 0.05)
    try? await Task.sleep(for: .milliseconds(100))

    #expect(await coordinator.events.isEmpty)
    #expect(presenter.hostedEvidenceShownStates().isEmpty)
    #expect(controller.status == "Ready")
    #expect(controller.lastError.isEmpty)
}

@MainActor
@Test("An undetermined microphone status still starts capture at once")
func undeterminedMicrophoneStartsCapture() async {
    let events = ShortcutEventLog()
    let hotkey = FilteringHotkeyService()
    let controller = makeTestDictationController(
        hotkey: hotkey,
        overlay: makeShortcutTestPresenter(),
        coordinator: ShortcutTestCoordinator(events: events)
    )
    defer { controller.teardown() }
    controller.microphoneAccessProvider = { .unknown }

    hotkey.press([.option])
    #expect(await waitForShortcutEvent("capture.start", in: events))
}

// MARK: - Test doubles

actor CaptureTestCoordinator: DictationSessionCoordinating {
    private let result: InsertResult
    private let startGate: ShortcutGate?
    private let startError: Error?
    private(set) var startedSessionIDs: [SessionID] = []
    private(set) var events: [String] = []

    init(result: InsertResult, startGate: ShortcutGate? = nil, startError: Error? = nil) {
        self.result = result
        self.startGate = startGate
        self.startError = startError
    }

    func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        events.append("start.requested")
        await startGate?.wait()
        if let startError {
            events.append("start.failed")
            throw startError
        }
        let sessionID = SessionID()
        startedSessionIDs.append(sessionID)
        events.append("start")
        return sessionID
    }

    func endPressToTalkCapture(sessionID: SessionID) async throws {
        events.append("end")
    }

    func completePressToTalk(sessionID: SessionID, languageHints: [String]) async throws -> InsertResult {
        events.append("complete")
        return result
    }

    func cancel(sessionID: SessionID) async {
        events.append("cancel")
    }

    func setHandsFreeEnabled(_ enabled: Bool) async {}
}
