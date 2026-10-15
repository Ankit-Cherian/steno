import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

// MARK: - The island's line for a stopped microphone

@Suite("The island's stopped-microphone line")
@MainActor
struct IslandMessageFitTests {
    /// A 13-inch Mac at its largest text setting.
    static let smallDisplay = OverlayDisplayDescriptor(
        id: 2, frame: CGRect(x: 0, y: 0, width: 1024, height: 640),
        visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 616), isBuiltIn: false, safeAreaTop: 0,
        auxiliaryTopLeft: nil, auxiliaryTopRight: nil
    )

    /// The island's fixed failure lines. Each replaces a system message that can run long.
    static let fixedMessages = [
        DictationController.microphoneStoppedWithoutSpeech,
        DictationController.recordingDidNotStart,
        DictationController.recordingDidNotFinish,
    ]

    @Test("Each fixed failure line on the island fits on its one line, at both text sizes")
    func fixedFailureLinesFit() throws {
        let long = CaptureInterruption(reason: .recorderStopped, deviceName: "Shure MV7+ Podcast Microphone (USB Audio Device)").message
        for bodySize in [CGFloat(13), 20] {
            var labels: [String: CGFloat] = [:]
            for message in Self.fixedMessages + [long] {
                let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
                presenter.hostedEvidencePrepareOffscreen()
                presenter.hostedEvidenceSetPlacement(.capsule(display: IslandMessageFitTests.smallDisplay))
                presenter.appearance = .grove
                presenter.updateAppearance(NSAppearance(named: .aqua))
                presenter.setHostedAccessibilityPreferences(.init(reduceMotion: true, reduceTransparency: false,
                                                                  increaseContrast: false, preferredBodyPointSize: bodySize))
                presenter.show(state: .listening(handsFree: true, elapsedSeconds: 30), insertedWords: nil)
                presenter.show(state: .failure(message: message), insertedWords: nil)
                labels[message] = presenter.hostedEvidenceGroveRowFrames()[.primary]?.width
                presenter.hide()
            }
            // The long warning is cut at the island's widest; a shorter line is narrower, so whole.
            let cut = try #require(labels[long], "no label")
            for message in Self.fixedMessages {
                let short = try #require(labels[message], "no label for \(message)")
                #expect(short + 40 < cut, "at \(bodySize) pt “\(message)” is \(short) pt and the cut warning \(cut) pt")
            }
        }
    }
}

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
    // The island's one line says what happened; the warning naming the microphone is in the window.
    #expect(presenter.hostedEvidenceShownStates().last == .failure(message: "Microphone stopped. No speech was heard."))
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
    #expect(presenter.hostedEvidenceRequestedStates().last
        == .result(.microphoneDisconnected(insertedPartial: true), showsWords: true))
    #expect(presenter.hostedEvidencePresentation()?.label == "Mic disconnected. Earlier words inserted.")
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
/// What the current overlay renders for `OverlayResult.microphoneAccessOff`.
private let renderedMicrophoneOffMessage = "Microphone access is off"

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
    #expect(presenter.hostedEvidenceRequestedStates() == [.result(.microphoneAccessOff, showsWords: true)])
    #expect(presenter.hostedEvidenceShownStates() == [.result(.microphoneAccessOff, showsWords: true)])
    #expect(presenter.hostedEvidenceUserFacingStrings().contains(renderedMicrophoneOffMessage))

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
        presenter.hostedEvidenceRequestedStates() == [.result(.microphoneAccessOff, showsWords: true)]
    })
    #expect(presenter.hostedEvidenceShownStates() == [.result(.microphoneAccessOff, showsWords: true)])
    #expect(presenter.hostedEvidenceUserFacingStrings().contains(renderedMicrophoneOffMessage))
    hotkey.press([], after: 1)

    #expect(await coordinator.events.isEmpty)
    #expect(controller.recordingLifecycleState == .idle)
    #expect(controller.lastError == microphoneOffMessage)
    // Releasing Option keeps the message that says why nothing was recorded.
    #expect(controller.status == "Microphone access is off.")
}

@MainActor
@Test("Releasing Option after a start refused because the runtime isn't ready keeps that message")
func refusedStartKeepsStatusAfterRelease() async {
    let hotkey = FilteringHotkeyService()
    let controller = makeTestDictationController(hotkey: hotkey, overlay: makeShortcutTestPresenter())
    defer { controller.teardown() }

    hotkey.press([.option])
    hotkey.holdPastConfirmationWindow()
    #expect(controller.status == "Runtime not ready yet.")
    hotkey.press([], after: 1)

    #expect(controller.recordingLifecycleState == .idle)
    #expect(controller.status == "Runtime not ready yet.")
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

// MARK: - A capture start that fails after the key is released

@MainActor
@Test("A press released before its capture start fails reports the recording error")
func releasedPressReportsCaptureStartFailure() async {
    let startGate = ShortcutGate()
    let presenter = makeShortcutTestPresenter()
    let coordinator = CaptureTestCoordinator(
        result: InsertResult(status: .inserted, method: .accessibility, insertedText: "unused"),
        startGate: startGate,
        startError: MacAudioCaptureError.failedToStartRecording
    )
    let controller = makeTestDictationController(
        hotkey: StatusReportingHotkeyService(),
        overlay: presenter,
        coordinator: coordinator
    )
    defer { controller.teardown() }

    controller.pressToTalkStart()
    #expect(await waitForShortcutCondition { await coordinator.events == ["start.requested"] })
    controller.pressToTalkStop()
    await startGate.open()

    #expect(await waitForShortcutCondition { controller.recordingLifecycleState == .idle })
    #expect(await waitForShortcutCondition { controller.lastError == "Failed to start audio recording" })
    #expect(controller.status == "Recording failed")
    // The island says what happened in its own words; the system's message is in the window.
    #expect(presenter.hostedEvidenceShownStates().last == .failure(message: "Couldn’t start recording."))
    #expect(!presenter.hostedEvidenceShownStates().contains(.failure(message: "Session not found")))
    #expect(await coordinator.events == ["start.requested", "start.failed"])
}

@MainActor
@Test("A capture that fails to start says so on the island in its own words, and keeps the system's message in the window")
func captureStartFailureShowsFixedIslandLine() async {
    let presenter = makeShortcutTestPresenter()
    let coordinator = CaptureTestCoordinator(
        result: InsertResult(status: .inserted, method: .accessibility, insertedText: "unused"),
        startError: MacAudioCaptureError.failedToStartRecording
    )
    let controller = makeTestDictationController(
        hotkey: StatusReportingHotkeyService(),
        overlay: presenter,
        coordinator: coordinator
    )
    defer { controller.teardown() }

    controller.pressToTalkStart()
    #expect(await waitForShortcutCondition { controller.status == "Failed to start" })
    #expect(controller.lastError == "Failed to start audio recording")
    #expect(presenter.hostedEvidenceShownStates().last == .failure(message: "Couldn’t start recording."))
}

@MainActor
@Test("A capture that fails to stop says so on the island in its own words, and keeps the system's message in the window")
func captureStopFailureShowsFixedIslandLine() async {
    let presenter = makeShortcutTestPresenter()
    let coordinator = StopFailingCaptureCoordinator()
    let controller = makeTestDictationController(
        hotkey: StatusReportingHotkeyService(),
        overlay: presenter,
        coordinator: coordinator
    )
    defer { controller.teardown() }

    controller.pressToTalkStart()
    #expect(await waitForShortcutCondition { controller.isRecording })
    controller.pressToTalkStop()
    #expect(await waitForShortcutCondition { controller.status == "Recording failed" })
    #expect(controller.lastError == StopFailingCaptureCoordinator.message)
    #expect(presenter.hostedEvidenceShownStates().last == .failure(message: "Couldn’t finish recording."))
}

/// Starts capture normally; closing it fails with a long system message.
private actor StopFailingCaptureCoordinator: DictationSessionCoordinating {
    static let message = "The audio file “Recording-2026-10-10.wav” couldn’t be closed because the volume is full."

    struct Failure: LocalizedError {
        var errorDescription: String? { StopFailingCaptureCoordinator.message }
    }

    private let sessionID = SessionID()

    func startPressToTalk(appContext: AppContext) async throws -> SessionID { sessionID }

    func startPressToTalkWithCaptureStopCapability(
        appContext: AppContext,
        options: SessionStartOptions,
        captureStarted: @Sendable (PressToTalkCaptureStopCapability) -> Void
    ) async throws -> SessionID {
        captureStarted(PressToTalkCaptureStopCapability(sessionID: sessionID, stopOperation: { throw Failure() },
                                                        cancelOperation: {}))
        return sessionID
    }

    func endPressToTalkCapture(sessionID: SessionID) async throws {}

    func completePressToTalk(sessionID: SessionID, languageHints: [String]) async throws -> InsertResult {
        InsertResult(status: .noSpeech, method: .none, insertedText: "")
    }

    func cancel(sessionID: SessionID) async {}

    func setHandsFreeEnabled(_ enabled: Bool) async {}
}

// MARK: - Media and presses that end quickly

@MainActor
@Test("A 200 ms press that ends while media is being checked sends no Pause and no Play")
func shortPressEndingDuringMediaCheckLeavesMediaAlone() async {
    let events = ShortcutEventLog()
    let media = ProbingTestMediaService(events: events)
    let hotkey = FilteringHotkeyService()
    let controller = makeTestDictationController(
        hotkey: hotkey,
        overlay: makeShortcutTestPresenter(),
        mediaInterruption: media,
        coordinator: ShortcutTestCoordinator(events: events)
    )
    defer { controller.teardown() }

    hotkey.press([.option])
    #expect(await waitForShortcutEvent("capture.start", in: events))
    hotkey.holdPastConfirmationWindow()
    // The media check has started, as it would about 150 ms into the press.
    #expect(await waitForShortcutEvent("media.probe", in: events))
    hotkey.press([], after: 0.05)
    // Capture closes at key-up; the check then finishes.
    #expect(await waitForShortcutEvent("capture.stop", in: events))
    await media.finishProbe()
    #expect(await waitForShortcutEvent("transcription.start", in: events))
    #expect(await waitForShortcutCondition { controller.recordingLifecycleState == .idle })
    try? await Task.sleep(for: .milliseconds(100))

    let recorded = await events.snapshot()
    #expect(!recorded.contains("media.pause"), "\(recorded)")
    #expect(!recorded.contains("media.release"), "\(recorded)")
}

@MainActor
@Test("A press that ends before the media check begins sends no Pause and no Play")
func pressEndingBeforeMediaCheckLeavesMediaAlone() async {
    let events = ShortcutEventLog()
    let startGate = ShortcutGate()
    let media = ProbingTestMediaService(events: events)
    let hotkey = FilteringHotkeyService()
    let coordinator = CaptureTestCoordinator(
        result: InsertResult(status: .inserted, method: .accessibility, insertedText: "Words"),
        startGate: startGate
    )
    let controller = makeTestDictationController(
        hotkey: hotkey,
        overlay: makeShortcutTestPresenter(),
        mediaInterruption: media,
        coordinator: coordinator
    )
    defer { controller.teardown() }

    hotkey.press([.option])
    #expect(await waitForShortcutCondition { await coordinator.events == ["start.requested"] })
    hotkey.holdPastConfirmationWindow()
    hotkey.press([], after: 0.05)
    await startGate.open()
    #expect(await waitForShortcutCondition { controller.lastTranscript == "Words" })
    await media.finishProbe()
    try? await Task.sleep(for: .milliseconds(100))

    let recorded = await events.snapshot()
    #expect(!recorded.contains("media.probe"), "\(recorded)")
    #expect(!recorded.contains("media.pause"), "\(recorded)")
    #expect(!recorded.contains("media.release"), "\(recorded)")
}

@MainActor
@Test("A press held past the media check still pauses and later resumes media")
func heldPressStillPausesMedia() async {
    let events = ShortcutEventLog()
    let media = ProbingTestMediaService(events: events)
    let hotkey = FilteringHotkeyService()
    let controller = makeTestDictationController(
        hotkey: hotkey,
        overlay: makeShortcutTestPresenter(),
        mediaInterruption: media,
        coordinator: ShortcutTestCoordinator(events: events)
    )
    defer { controller.teardown() }

    hotkey.press([.option])
    hotkey.holdPastConfirmationWindow()
    #expect(await waitForShortcutEvent("media.probe", in: events))
    await media.finishProbe()
    #expect(await waitForShortcutEvent("media.pause", in: events))
    hotkey.press([], after: 1)
    #expect(await waitForShortcutEvent("media.release", in: events))
}

// MARK: - Test doubles

/// Checks for playing media before pausing, like the production service, and
/// sends no Pause when the begin call is cancelled during the check.
@MainActor
final class ProbingTestMediaService: MediaInterruptionService {
    private let events: ShortcutEventLog
    private let probeGate = ShortcutGate()

    init(events: ShortcutEventLog) {
        self.events = events
    }

    func finishProbe() async {
        await probeGate.open()
    }

    func beginInterruption() async -> MediaInterruptionToken? {
        await events.append("media.probe")
        await probeGate.wait()
        guard !Task.isCancelled else { return nil }
        await events.append("media.pause")
        return MediaInterruptionToken()
    }

    func endInterruption(token: MediaInterruptionToken) async {
        await events.append("media.release")
    }
}

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

// MARK: - A Stop that arrives before capture has begun

/// How a Stop reaches the controller: the hands-free key or the menu's
/// Dictate item pressed again, the Stop button in the overlay, the menu
/// panel or Today, or an Option release.
enum EarlyStopRoute: String, CaseIterable, Sendable {
    case handsFreeToggle
    case stopButton
    case optionRelease
}

@MainActor
@Test("A Stop that arrives before capture has begun stops capture once it starts, and the words are transcribed",
      arguments: EarlyStopRoute.allCases)
func stopBeforeCaptureBeginsIsTranscribed(route: EarlyStopRoute) async {
    let presenter = makeShortcutTestPresenter()
    let coordinator = CaptureTestCoordinator(
        result: InsertResult(status: .inserted, method: .accessibility, insertedText: "Words")
    )
    let controller = makeTestDictationController(
        hotkey: StatusReportingHotkeyService(),
        overlay: presenter,
        coordinator: coordinator
    )
    defer { controller.teardown() }

    // Start and Stop in the same main-actor turn, before the start has
    // reached the coordinator.
    switch route {
    case .handsFreeToggle:
        controller.toggleHandsFree()
        controller.toggleHandsFree()
    case .stopButton:
        controller.toggleHandsFree()
        controller.stopRecording()
    case .optionRelease:
        controller.pressToTalkStart()
        controller.pressToTalkStop()
    }

    #expect(await waitForShortcutCondition { controller.lastTranscript == "Words" }, "status: \(controller.status)")
    #expect(await waitForShortcutCondition { controller.recordingLifecycleState == .idle })
    let events = await coordinator.events
    #expect(events.prefix(3) == ["start.requested", "start", "end"], "\(events)")
    #expect(events.last == "complete", "\(events)")
    #expect(!events.contains("cancel"), "\(events)")
    #expect(controller.status == "Transcript inserted.")
    #expect(!controller.isRecording)
}
