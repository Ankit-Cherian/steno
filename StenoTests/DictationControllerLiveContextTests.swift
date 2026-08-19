import Foundation
import Testing
@testable import Steno
@testable import StenoKit

@Test("Capture display follows the frontmost app window instead of the pointer")
func captureDisplayUsesFrontmostWindowGeometry() {
    let windows = [
        CaptureTargetWindowGeometry(
            ownerProcessID: 41,
            layer: 0,
            quartzBounds: CGRect(x: 1_200, y: 100, width: 800, height: 600)
        )
    ]
    let screens = [
        CaptureTargetScreenGeometry(
            appKitFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            quartzFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        ),
        CaptureTargetScreenGeometry(
            appKitFrame: CGRect(x: 1_000, y: 0, width: 1_200, height: 900),
            quartzFrame: CGRect(x: 1_000, y: 0, width: 1_200, height: 900)
        )
    ]

    let selected = CaptureTargetDisplaySelector.point(
        processID: 41,
        windows: windows,
        screens: screens,
        fallback: CGPoint(x: 200, y: 200)
    )

    #expect(selected == CGPoint(x: 1_600, y: 450))
}

@Test("Capture display selector fails closed to the pointer without a target window")
func captureDisplayFallsBackWithoutMatchingWindow() {
    let fallback = CGPoint(x: 123, y: 456)
    let selected = CaptureTargetDisplaySelector.point(
        processID: 41,
        windows: [
            CaptureTargetWindowGeometry(
                ownerProcessID: 99,
                layer: 0,
                quartzBounds: CGRect(x: 0, y: 0, width: 500, height: 500)
            )
        ],
        screens: [],
        fallback: fallback
    )

    #expect(selected == fallback)
}

@MainActor
@Test("Controller forwards one capture generation and both privacy controls")
func controllerForwardsLiveContextStartOptions() async {
    let coordinator = LiveContextOptionsCoordinator()
    let controller = DictationController(
        hotkey: LiveContextHotkeyService(),
        mediaInterruption: LiveContextMediaInterruptionService(),
        coordinator: coordinator
    )
    controller.preferences.dictation.showLiveTranscriptWhileRecording = false
    controller.preferences.dictation.useNearbyTextForContinuation = true

    controller.pressToTalkStart()

    guard await waitForLiveContextCondition({ await coordinator.options() != nil }) else {
        Issue.record("Controller did not start the injected coordinator")
        controller.teardown()
        return
    }
    let options = await coordinator.options()
    #expect(options?.livePreviewEnabled == false)
    #expect(options?.nearbyContextEnabled == true)
    #expect(options?.languageHints == ["en-US"])
    #expect(await coordinator.legacyStartCount() == 0)

    controller.cancelActiveRecording()
    await controller.teardownAndWait()
}

@MainActor
@Test("Controller waits for capture acknowledgement before presenting listening UI")
func controllerPresentsOnlyAfterCaptureAcknowledgement() async {
    let coordinator = GatedCaptureAcknowledgementCoordinator()
    let presenter = WaveformOverlayPresenter()
    presenter.prepareWindow()
    var listeningPresentationCount = 0
    presenter.setHostedEvidenceHandler { event in
        if case .listeningPresented = event {
            listeningPresentationCount += 1
        }
    }
    let controller = DictationController(
        hotkey: LiveContextHotkeyService(),
        overlay: presenter,
        mediaInterruption: LiveContextMediaInterruptionService(),
        coordinator: coordinator
    )

    controller.pressToTalkStart()
    #expect(await waitForLiveContextCondition { await coordinator.isWaitingForCapture() })
    #expect(listeningPresentationCount == 0)
    #expect(controller.isRecording == false)

    await coordinator.acknowledgeCapture()
    #expect(await waitForLiveContextCondition { listeningPresentationCount == 1 })
    #expect(controller.isRecording)

    controller.cancelActiveRecording()
    presenter.setHostedEvidenceHandler(nil)
    await controller.teardownAndWait()
}

@MainActor
@Test("Exact target drift reports that the final transcript was copied")
func exactTargetDriftUsesTruthfulCopiedStatus() async {
    let coordinator = LiveContextOptionsCoordinator(
        completionResult: InsertResult(
            status: .copiedOnly,
            method: .clipboardPaste,
            insertedText: "final words",
            errorMessage: "Exact editor target is unavailable: selectionChanged."
        )
    )
    let controller = DictationController(
        hotkey: LiveContextHotkeyService(),
        mediaInterruption: LiveContextMediaInterruptionService(),
        coordinator: coordinator
    )

    controller.pressToTalkStart()
    guard await waitForLiveContextCondition({ await coordinator.options() != nil }) else {
        Issue.record("Controller did not start the injected coordinator")
        controller.teardown()
        return
    }
    controller.pressToTalkStop()

    #expect(await waitForLiveContextCondition {
        controller.status == "Target changed—final text copied."
    })
    #expect(controller.lastTranscript == "final words")
    await controller.teardownAndWait()
}

@MainActor
@Test("Short key-up before capability publication finalizes once")
func controllerFinalizesStopRequestedBeforeCapabilityPublication() async {
    let publicationGate = LiveContextLifecycleGate()
    let capture = ControllerCaptureProbe()
    let coordinator = EarlyStopCoordinator(
        capture: capture,
        beforePublicationGate: publicationGate
    )
    let controller = DictationController(
        hotkey: LiveContextHotkeyService(),
        mediaInterruption: LiveContextMediaInterruptionService(),
        coordinator: coordinator
    )
    controller.preferences.media.pauseDuringPressToTalk = false

    controller.pressToTalkStart()
    #expect(await waitForLiveContextCondition { await publicationGate.isWaiting })
    controller.pressToTalkStop()
    #expect(capture.stopCalls == 0)

    await publicationGate.open()
    #expect(await waitForLiveContextCondition { await coordinator.completeCalls == 1 })
    #expect(capture.stopCalls == 1)
    #expect(capture.cancelCalls == 0)
    #expect(await coordinator.endCalls == 1)
    #expect(await coordinator.cancelCalls == 0)
    #expect(controller.status == "No speech detected.")
    await controller.teardownAndWait()
}

@MainActor
@Test("Cancel before capability publication discards without finalizing")
func controllerCancelsBeforeCapabilityPublication() async {
    let publicationGate = LiveContextLifecycleGate()
    let capture = ControllerCaptureProbe()
    let coordinator = EarlyStopCoordinator(
        capture: capture,
        beforePublicationGate: publicationGate
    )
    let controller = DictationController(
        hotkey: LiveContextHotkeyService(),
        mediaInterruption: LiveContextMediaInterruptionService(),
        coordinator: coordinator
    )
    controller.preferences.media.pauseDuringPressToTalk = false

    controller.pressToTalkStart()
    #expect(await waitForLiveContextCondition { await publicationGate.isWaiting })
    controller.cancelActiveRecording()
    await publicationGate.open()

    #expect(await waitForLiveContextCondition { capture.cancelCalls == 1 })
    #expect(capture.stopCalls == 0)
    #expect(await coordinator.completeCalls == 0)
    #expect(controller.status == "Recording canceled.")
    await controller.teardownAndWait()
}

@MainActor
@Test("Key-up closes capture while coordinator start remains blocked")
func controllerStopsCaptureBeforeBlockedStartReturns() async {
    let blockedStartGate = LiveContextLifecycleGate()
    let capture = ControllerCaptureProbe()
    let coordinator = EarlyStopCoordinator(
        capture: capture,
        afterPublicationGate: blockedStartGate
    )
    let controller = DictationController(
        hotkey: LiveContextHotkeyService(),
        mediaInterruption: LiveContextMediaInterruptionService(),
        coordinator: coordinator
    )
    controller.preferences.media.pauseDuringPressToTalk = false

    controller.pressToTalkStart()
    #expect(await waitForLiveContextCondition { await blockedStartGate.isWaiting })
    controller.pressToTalkStop()
    #expect(await waitForLiveContextCondition { capture.stopCalls == 1 })
    #expect(await blockedStartGate.isWaiting)
    #expect(await coordinator.endCalls == 0)
    #expect(await coordinator.completeCalls == 0)

    await blockedStartGate.open()
    #expect(await waitForLiveContextCondition { await coordinator.completeCalls == 1 })
    #expect(capture.stopCalls == 1)
    #expect(capture.cancelCalls == 0)
    #expect(await coordinator.endCalls == 1)
    #expect(await coordinator.cancelCalls == 0)
    await controller.teardownAndWait()
}

@MainActor
@Test("Key-up closes capture before blocked media begin settles")
func controllerStopsCaptureBeforeBlockedMediaBeginSettles() async {
    let mediaGate = LiveContextLifecycleGate()
    let capture = ControllerCaptureProbe()
    let coordinator = EarlyStopCoordinator(capture: capture)
    let media = GatedLiveContextMediaInterruptionService(
        gate: mediaGate,
        capture: capture
    )
    let controller = DictationController(
        hotkey: LiveContextHotkeyService(),
        mediaInterruption: media,
        coordinator: coordinator
    )
    controller.preferences.media.pauseDuringPressToTalk = true

    controller.pressToTalkStart()
    #expect(await waitForLiveContextCondition { await mediaGate.isWaiting })
    controller.pressToTalkStop()
    #expect(await waitForLiveContextCondition { capture.stopCalls == 1 })
    #expect(await coordinator.endCalls == 0)
    #expect(await coordinator.completeCalls == 0)

    await mediaGate.open()
    #expect(await waitForLiveContextCondition { await coordinator.completeCalls == 1 })
    #expect(await media.endCalls == 1)
    let events = capture.events
    guard let stopIndex = events.firstIndex(of: "capture.stop"),
          let releaseIndex = events.firstIndex(of: "media.end"),
          let completeIndex = events.firstIndex(of: "coordinator.complete") else {
        Issue.record("Missing lifecycle events: \(events)")
        await controller.teardownAndWait()
        return
    }
    #expect(stopIndex < releaseIndex)
    #expect(releaseIndex < completeIndex)
    #expect(capture.cancelCalls == 0)
    await controller.teardownAndWait()
}

@MainActor
@Test("Cancel and teardown close capture while coordinator start is blocked")
func controllerCancelAndTeardownCloseBlockedCapture() async {
    let cancelGate = LiveContextLifecycleGate()
    let cancelCapture = ControllerCaptureProbe()
    let cancelCoordinator = EarlyStopCoordinator(
        capture: cancelCapture,
        afterPublicationGate: cancelGate
    )
    let cancelController = DictationController(
        hotkey: LiveContextHotkeyService(),
        mediaInterruption: LiveContextMediaInterruptionService(),
        coordinator: cancelCoordinator
    )
    cancelController.preferences.media.pauseDuringPressToTalk = false
    cancelController.pressToTalkStart()
    #expect(await waitForLiveContextCondition { await cancelGate.isWaiting })
    cancelController.cancelActiveRecording()
    #expect(await waitForLiveContextCondition { cancelCapture.cancelCalls == 1 })
    #expect(await cancelGate.isWaiting)
    await cancelGate.open()
    await cancelController.teardownAndWait()
    #expect(cancelCapture.cancelCalls == 1)
    #expect(await cancelCoordinator.completeCalls == 0)

    let teardownGate = LiveContextLifecycleGate()
    let teardownCapture = ControllerCaptureProbe()
    let teardownCoordinator = EarlyStopCoordinator(
        capture: teardownCapture,
        afterPublicationGate: teardownGate
    )
    let teardownController = DictationController(
        hotkey: LiveContextHotkeyService(),
        mediaInterruption: LiveContextMediaInterruptionService(),
        coordinator: teardownCoordinator
    )
    teardownController.preferences.media.pauseDuringPressToTalk = false
    teardownController.pressToTalkStart()
    #expect(await waitForLiveContextCondition { await teardownGate.isWaiting })
    teardownController.teardown()
    #expect(await waitForLiveContextCondition { teardownCapture.cancelCalls == 1 })
    #expect(await teardownGate.isWaiting)
    await teardownGate.open()
    await teardownController.teardownAndWait()
    #expect(teardownCapture.cancelCalls == 1)
    #expect(await teardownCoordinator.completeCalls == 0)
}

private actor LiveContextOptionsCoordinator: DictationSessionCoordinating {
    private var receivedOptions: SessionStartOptions?
    private var oldStartCount = 0
    private let sessionID = SessionID()
    private let completionResult: InsertResult

    init(
        completionResult: InsertResult = InsertResult(
            status: .noSpeech,
            method: .none,
            insertedText: ""
        )
    ) {
        self.completionResult = completionResult
    }

    func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        oldStartCount += 1
        return sessionID
    }

    func startPressToTalk(
        appContext: AppContext,
        options: SessionStartOptions
    ) async throws -> SessionID {
        receivedOptions = options
        return sessionID
    }

    func endPressToTalkCapture(sessionID: SessionID) async throws {}

    func completePressToTalk(
        sessionID: SessionID,
        languageHints: [String]
    ) async throws -> InsertResult {
        completionResult
    }

    func cancel(sessionID: SessionID) async {}
    func setHandsFreeEnabled(_ enabled: Bool) async {}

    func options() -> SessionStartOptions? {
        receivedOptions
    }

    func legacyStartCount() -> Int {
        oldStartCount
    }
}

private actor GatedCaptureAcknowledgementCoordinator: DictationSessionCoordinating {
    private let sessionID = SessionID()
    private var captureContinuation: CheckedContinuation<Void, Never>?

    func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        _ = appContext
        return sessionID
    }

    func startPressToTalk(
        appContext: AppContext,
        options: SessionStartOptions
    ) async throws -> SessionID {
        _ = appContext
        _ = options
        await withCheckedContinuation { continuation in
            captureContinuation = continuation
        }
        return sessionID
    }

    func isWaitingForCapture() -> Bool {
        captureContinuation != nil
    }

    func acknowledgeCapture() {
        captureContinuation?.resume()
        captureContinuation = nil
    }

    func endPressToTalkCapture(sessionID: SessionID) async throws { _ = sessionID }

    func completePressToTalk(
        sessionID: SessionID,
        languageHints: [String]
    ) async throws -> InsertResult {
        _ = sessionID
        _ = languageHints
        return InsertResult(status: .noSpeech, method: .none, insertedText: "")
    }

    func cancel(sessionID: SessionID) async { _ = sessionID }
    func setHandsFreeEnabled(_ enabled: Bool) async { _ = enabled }
}

private actor LiveContextLifecycleGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var openState = false
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        guard !openState else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        openState = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class ControllerCaptureProbe: @unchecked Sendable {
    private enum State {
        case open
        case stopped
        case cancelled
    }

    private let lock = NSLock()
    private var state: State = .open
    private var storedStopCalls = 0
    private var storedCancelCalls = 0
    private var storedMarkCalls = 0
    private var storedEvents: [String] = []

    var stopCalls: Int { lock.withLock { storedStopCalls } }
    var cancelCalls: Int { lock.withLock { storedCancelCalls } }
    var markCalls: Int { lock.withLock { storedMarkCalls } }
    var events: [String] { lock.withLock { storedEvents } }

    func record(_ event: String) {
        lock.withLock { storedEvents.append(event) }
    }

    func markStopRequested() {
        lock.withLock { storedMarkCalls += 1 }
    }

    func stop() throws {
        try lock.withLock {
            switch state {
            case .open:
                state = .stopped
                storedStopCalls += 1
                storedEvents.append("capture.stop")
            case .stopped:
                break
            case .cancelled:
                throw CancellationError()
            }
        }
    }

    func cancel() {
        lock.withLock {
            guard state == .open else { return }
            state = .cancelled
            storedCancelCalls += 1
            storedEvents.append("capture.cancel")
        }
    }
}

private actor EarlyStopCoordinator: DictationSessionCoordinating {
    private let sessionID = SessionID()
    private let capture: ControllerCaptureProbe
    private let beforePublicationGate: LiveContextLifecycleGate?
    private let afterPublicationGate: LiveContextLifecycleGate?
    private(set) var endCalls = 0
    private(set) var completeCalls = 0
    private(set) var cancelCalls = 0

    init(
        capture: ControllerCaptureProbe,
        beforePublicationGate: LiveContextLifecycleGate? = nil,
        afterPublicationGate: LiveContextLifecycleGate? = nil
    ) {
        self.capture = capture
        self.beforePublicationGate = beforePublicationGate
        self.afterPublicationGate = afterPublicationGate
    }

    func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        _ = appContext
        return sessionID
    }

    func startPressToTalkWithCaptureStopCapability(
        appContext: AppContext,
        options: SessionStartOptions,
        captureStarted: @Sendable (PressToTalkCaptureStopCapability) -> Void
    ) async throws -> SessionID {
        _ = appContext
        _ = options
        capture.record("capture.begin")
        await beforePublicationGate?.wait()
        capture.record("capture.published")
        captureStarted(PressToTalkCaptureStopCapability(
            sessionID: sessionID,
            stopOperation: { [capture] in try capture.stop() },
            cancelOperation: { [capture] in capture.cancel() },
            markStopRequestedOperation: { [capture] in capture.markStopRequested() }
        ))
        await afterPublicationGate?.wait()
        return sessionID
    }

    func endPressToTalkCapture(sessionID: SessionID) async throws {
        _ = sessionID
        endCalls += 1
        capture.record("coordinator.end")
    }

    func completePressToTalk(
        sessionID: SessionID,
        languageHints: [String]
    ) async throws -> InsertResult {
        _ = sessionID
        _ = languageHints
        completeCalls += 1
        capture.record("coordinator.complete")
        return InsertResult(status: .noSpeech, method: .none, insertedText: "")
    }

    func cancel(sessionID: SessionID) async {
        _ = sessionID
        cancelCalls += 1
        capture.cancel()
        capture.record("coordinator.cancel")
    }

    func setHandsFreeEnabled(_ enabled: Bool) async { _ = enabled }
}

@MainActor
private final class LiveContextHotkeyService: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16? = 79

    func start() {}
    func stop() {}
}

@MainActor
private final class LiveContextMediaInterruptionService: MediaInterruptionService {
    func beginInterruption() async -> MediaInterruptionToken? { nil }
    func endInterruption(token: MediaInterruptionToken) async {}
}

@MainActor
private final class GatedLiveContextMediaInterruptionService: MediaInterruptionService {
    private let gate: LiveContextLifecycleGate
    private let capture: ControllerCaptureProbe
    private(set) var endCalls = 0

    init(gate: LiveContextLifecycleGate, capture: ControllerCaptureProbe) {
        self.gate = gate
        self.capture = capture
    }

    func beginInterruption() async -> MediaInterruptionToken? {
        capture.record("media.begin")
        await gate.wait()
        capture.record("media.token")
        return MediaInterruptionToken()
    }

    func endInterruption(token: MediaInterruptionToken) async {
        _ = token
        endCalls += 1
        capture.record("media.end")
    }
}

@MainActor
private func waitForLiveContextCondition(
    timeout: TimeInterval = 2,
    _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}
