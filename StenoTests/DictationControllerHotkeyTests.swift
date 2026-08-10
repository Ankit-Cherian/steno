import Foundation
import Testing
@testable import Steno
import StenoKit

@MainActor
@Test("Save and apply updates the live hands-free hotkey")
func saveAndApplyUpdatesLiveHandsFreeHotkey() async throws {
    let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoTests-\(UUID().uuidString)", isDirectory: true)
    let preferencesURL = testDirectory.appendingPathComponent("preferences.json")
    let hotkey = FakeHotkeyService()
    hotkey.globalToggleKeyCode = 96
    let controller = DictationController(
        hotkey: hotkey,
        preferencesStore: AppPreferencesStore(storageURL: preferencesURL)
    )
    defer {
        controller.teardown()
        try? FileManager.default.removeItem(at: testDirectory)
    }

    var draft = controller.preferences
    draft.hotkeys.handsFreeGlobalKeyCode = 107

    controller.applySettingsDraft(preferences: draft)

    #expect(controller.preferences.hotkeys.handsFreeGlobalKeyCode == 107)
    #expect(hotkey.globalToggleKeyCode == 107)
    #expect(await waitForCondition {
        FileManager.default.fileExists(atPath: preferencesURL.path)
            && controller.status == "Running local transcription + local cleanup."
    })
    let savedPreferences = try JSONDecoder().decode(
        AppPreferences.self,
        from: Data(contentsOf: preferencesURL)
    )
    #expect(savedPreferences.hotkeys.handsFreeGlobalKeyCode == 107)
}

@Test("Option held through cleanup starts when cleanup finishes")
func optionHeldThroughCleanupIsDeferred() {
    var gate = SessionCleanupStartGate()
    gate.beginCleanup()

    let didDefer = gate.deferPressToTalkStart()
    #expect(didDefer)
    #expect(gate.finishCleanup() == .pressToTalk)
}

@Test("Option released during cleanup cancels the deferred start")
func optionReleasedDuringCleanupCancelsDeferredStart() {
    var gate = SessionCleanupStartGate()
    gate.beginCleanup()

    let didDefer = gate.deferPressToTalkStart()
    let didCancel = gate.cancelDeferredPressToTalkStart()
    #expect(didDefer)
    #expect(didCancel)
    #expect(gate.finishCleanup() == nil)
}

@Test("Hands-free toggle during cleanup is deferred and can be toggled off")
func handsFreeToggleDuringCleanupIsDeferred() {
    var gate = SessionCleanupStartGate()
    gate.beginCleanup()

    let didDefer = gate.deferHandsFreeToggle()
    #expect(didDefer)
    #expect(gate.deferredMode == .handsFree)
    let didCancel = gate.deferHandsFreeToggle()
    #expect(didCancel)
    #expect(gate.deferredMode == nil)
    #expect(gate.finishCleanup() == nil)
}

@MainActor
@Test("Press-to-talk starts capture before checking media")
func pressToTalkStartsCaptureBeforeCheckingMedia() async {
    let events = LifecycleEventLog()
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: FakeMediaInterruptionService(events: events),
        coordinator: FakeDictationCoordinator(events: events)
    )

    controller.pressToTalkStart()
    guard await waitForLifecycleEvent("media.pause", in: events) else {
        Issue.record("Start events: \(await events.snapshot()); status: \(controller.status)")
        controller.teardown()
        return
    }

    assertEventOrder("capture.start", before: "media.pause", in: await events.snapshot())
    controller.teardown()
}

@MainActor
@Test("Hands-free checks media before starting capture")
func handsFreeChecksMediaBeforeStartingCapture() async {
    let events = LifecycleEventLog()
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: FakeMediaInterruptionService(events: events),
        coordinator: FakeDictationCoordinator(events: events)
    )

    controller.toggleHandsFree()
    guard await waitForLifecycleEvent("capture.start", in: events) else {
        Issue.record("Start events: \(await events.snapshot()); status: \(controller.status)")
        controller.teardown()
        return
    }

    assertEventOrder("media.pause", before: "capture.start", in: await events.snapshot())
    controller.teardown()
}

@MainActor
@Test("Normal stop closes the capture before media ownership releases")
func normalStopClosesCaptureBeforeMediaRelease() async {
    let events = LifecycleEventLog()
    let coordinator = FakeDictationCoordinator(events: events)
    let media = FakeMediaInterruptionService(events: events)
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: media,
        coordinator: coordinator
    )

    controller.pressToTalkStart()
    guard await waitForLifecycleEvent("media.pause", in: events) else {
        Issue.record("Start events: \(await events.snapshot()); status: \(controller.status)")
        controller.teardown()
        return
    }
    controller.pressToTalkStop()
    guard await waitForLifecycleEvent("media.release", in: events) else {
        Issue.record("Stop events: \(await events.snapshot()); status: \(controller.status)")
        controller.teardown()
        return
    }

    let snapshot = await events.snapshot()
    guard let stopIndex = snapshot.firstIndex(of: "capture.stop"),
          let releaseIndex = snapshot.firstIndex(of: "media.release")
    else {
        Issue.record("Missing expected lifecycle events: \(snapshot)")
        controller.teardown()
        return
    }
    #expect(stopIndex < releaseIndex)
    controller.teardown()
}

@MainActor
@Test("Media resumes after capture closes without waiting for transcription")
func mediaResumesImmediatelyAfterCaptureCloses() async {
    let events = LifecycleEventLog()
    let processingGate = LifecycleGate()
    let coordinator = FakeDictationCoordinator(
        events: events,
        processingGate: processingGate
    )
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: FakeMediaInterruptionService(events: events),
        coordinator: coordinator
    )

    controller.pressToTalkStart()
    guard await waitForLifecycleEvent("media.pause", in: events) else {
        Issue.record("Start events: \(await events.snapshot()); status: \(controller.status)")
        controller.teardown()
        return
    }
    controller.pressToTalkStop()
    guard await waitForLifecycleEvent("transcription.start", in: events) else {
        Issue.record("Stop events: \(await events.snapshot()); status: \(controller.status)")
        controller.teardown()
        return
    }

    let resumedBeforeProcessingFinished = await waitForLifecycleEvent(
        "media.release",
        in: events,
        attempts: 40
    )
    await processingGate.open()

    #expect(resumedBeforeProcessingFinished)
    assertEventOrder("capture.stop", before: "media.release", in: await events.snapshot())
    controller.teardown()
}

@MainActor
@Test("Teardown cancels in-flight transcription without a late UI update")
func teardownCancelsInFlightTranscription() async {
    let events = LifecycleEventLog()
    let processingGate = LifecycleGate()
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: FakeMediaInterruptionService(events: events),
        coordinator: FakeDictationCoordinator(
            events: events,
            processingGate: processingGate
        )
    )

    controller.pressToTalkStart()
    guard await waitForLifecycleEvent("media.pause", in: events) else {
        Issue.record("Start events: \(await events.snapshot()); status: \(controller.status)")
        controller.teardown()
        return
    }
    controller.pressToTalkStop()
    guard await waitForLifecycleEvent("transcription.start", in: events),
          await waitForLifecycleEvent("media.release", in: events)
    else {
        Issue.record("Processing events: \(await events.snapshot()); status: \(controller.status)")
        controller.teardown()
        return
    }

    controller.teardown()
    let statusAtTeardown = controller.status
    await processingGate.open()

    #expect(await waitForLifecycleEvent("capture.cancel", in: events))
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(controller.status == statusAtTeardown)
    #expect((await events.snapshot()).filter { $0 == "media.release" }.count == 1)
}

@MainActor
@Test("Stop failure cancels capture before media ownership releases")
func stopFailureCancelsCaptureBeforeMediaRelease() async {
    let events = LifecycleEventLog()
    let coordinator = FakeDictationCoordinator(events: events, stopShouldFail: true)
    let media = FakeMediaInterruptionService(events: events)
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: media,
        coordinator: coordinator
    )

    controller.pressToTalkStart()
    guard await waitForLifecycleEvent("media.pause", in: events) else {
        Issue.record("Start events: \(await events.snapshot()); status: \(controller.status)")
        controller.teardown()
        return
    }
    controller.pressToTalkStop()
    guard await waitForLifecycleEvent("media.release", in: events) else {
        Issue.record("Failure events: \(await events.snapshot()); status: \(controller.status)")
        controller.teardown()
        return
    }

    let snapshot = await events.snapshot()
    guard let cancelIndex = snapshot.firstIndex(of: "capture.cancel"),
          let releaseIndex = snapshot.firstIndex(of: "media.release")
    else {
        Issue.record("Missing expected lifecycle events: \(snapshot)")
        controller.teardown()
        return
    }
    #expect(cancelIndex < releaseIndex)
    controller.teardown()
}

@MainActor
@Test("Explicit cancel closes capture before media ownership releases")
func explicitCancelClosesCaptureBeforeMediaRelease() async {
    let events = LifecycleEventLog()
    let coordinator = FakeDictationCoordinator(events: events)
    let media = FakeMediaInterruptionService(events: events)
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: media,
        coordinator: coordinator
    )

    controller.pressToTalkStart()
    guard await waitForLifecycleEvent("media.pause", in: events) else {
        Issue.record("Start events: \(await events.snapshot()); status: \(controller.status)")
        controller.teardown()
        return
    }
    controller.cancelActiveRecording()
    guard await waitForLifecycleEvent("media.release", in: events) else {
        Issue.record("Cancel events: \(await events.snapshot()); status: \(controller.status)")
        controller.teardown()
        return
    }

    assertCaptureCancelPrecedesMediaRelease(await events.snapshot())
    controller.teardown()
}

@MainActor
@Test("Teardown closes capture before media ownership releases")
func teardownClosesCaptureBeforeMediaRelease() async {
    let events = LifecycleEventLog()
    let coordinator = FakeDictationCoordinator(events: events)
    let media = FakeMediaInterruptionService(events: events)
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: media,
        coordinator: coordinator
    )

    controller.pressToTalkStart()
    guard await waitForLifecycleEvent("media.pause", in: events) else {
        Issue.record("Start events: \(await events.snapshot()); status: \(controller.status)")
        controller.teardown()
        return
    }
    controller.teardown()
    guard await waitForLifecycleEvent("media.release", in: events) else {
        Issue.record("Teardown events: \(await events.snapshot()); status: \(controller.status)")
        return
    }

    assertCaptureCancelPrecedesMediaRelease(await events.snapshot())
}

@MainActor
@Test("Teardown during deferred cleanup cannot restart recording")
func teardownDuringDeferredCleanupCannotRestartRecording() async {
    let events = LifecycleEventLog()
    let cancelGate = LifecycleGate()
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: FakeMediaInterruptionService(events: events),
        coordinator: FakeDictationCoordinator(events: events, cancelGate: cancelGate)
    )

    controller.pressToTalkStart()
    guard await waitForLifecycleEvent("media.pause", in: events) else {
        Issue.record("Start events: \(await events.snapshot()); status: \(controller.status)")
        controller.teardown()
        return
    }
    controller.cancelActiveRecording()
    controller.pressToTalkStart()
    guard await waitForLifecycleEvent("capture.cancel", in: events) else {
        Issue.record("Cancel events: \(await events.snapshot()); status: \(controller.status)")
        controller.teardown()
        return
    }

    controller.teardown()
    await cancelGate.open()
    guard await waitForLifecycleEvent("media.release", in: events) else {
        Issue.record("Teardown events: \(await events.snapshot()); status: \(controller.status)")
        return
    }
    try? await Task.sleep(nanoseconds: 20_000_000)

    let snapshot = await events.snapshot()
    #expect(snapshot.filter { $0 == "capture.start" }.count == 1)
}

@MainActor
@Test("Cancel stays bound to the coordinator that owns the session")
func cancelUsesSessionOwningCoordinatorAfterReplacement() async {
    let events = LifecycleEventLog()
    let owner = FakeDictationCoordinator(events: events, eventPrefix: "owner")
    let replacement = FakeDictationCoordinator(events: events, eventPrefix: "replacement")
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: FakeMediaInterruptionService(events: events),
        coordinator: owner
    )

    controller.pressToTalkStart()
    guard await waitForLifecycleEvent("owner.capture.ready", in: events),
          await waitForCondition({ !controller.lifecycleDiagnostics.hasActiveStartTask })
    else {
        Issue.record("Start did not settle: \(await events.snapshot())")
        controller.teardown()
        return
    }

    controller.cancelActiveRecording()
    controller.replaceCoordinatorForLifecycleTesting(replacement)

    guard await waitForAnyLifecycleEvent(
        ["owner.capture.cancel", "replacement.capture.cancel"],
        in: events
    ) else {
        Issue.record("Cancel did not reach a coordinator: \(await events.snapshot())")
        controller.teardown()
        return
    }

    let snapshot = await events.snapshot()
    #expect(snapshot.contains("owner.capture.cancel"))
    #expect(!snapshot.contains("replacement.capture.cancel"))
    controller.teardown()
}

@MainActor
@Test("Settings rebuild waits for session cleanup")
func settingsRebuildWaitsForSessionCleanup() async {
    let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoTests-\(UUID().uuidString)", isDirectory: true)
    let events = LifecycleEventLog()
    let cancelGate = LifecycleGate()
    let rebuilds = AsyncCounter()
    let owner = FakeDictationCoordinator(
        events: events,
        cancelGate: cancelGate,
        eventPrefix: "owner"
    )
    let replacement = FakeDictationCoordinator(events: events, eventPrefix: "replacement")
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: FakeMediaInterruptionService(events: events),
        preferencesStore: AppPreferencesStore(
            storageURL: testDirectory.appendingPathComponent("preferences.json")
        ),
        coordinator: owner,
        runtimeRebuildOverride: {
            await rebuilds.increment()
            return replacement
        }
    )
    defer {
        controller.teardown()
        try? FileManager.default.removeItem(at: testDirectory)
    }

    controller.pressToTalkStart()
    guard await waitForLifecycleEvent("owner.capture.ready", in: events),
          await waitForCondition({ !controller.lifecycleDiagnostics.hasActiveStartTask })
    else {
        Issue.record("Start did not settle: \(await events.snapshot())")
        return
    }

    controller.cancelActiveRecording()
    guard await waitForLifecycleEvent("owner.capture.cancel", in: events) else {
        Issue.record("Cleanup did not begin: \(await events.snapshot())")
        return
    }

    controller.applySettingsDraft(preferences: controller.preferences)
    guard await waitForCondition({ controller.lifecycleDiagnostics.hasPendingRuntimeRebuild }) else {
        Issue.record("Settings did not defer during cleanup; rebuilds: \(await rebuilds.value())")
        return
    }

    #expect(controller.lifecycleDiagnostics.isCleanupInProgress)
    #expect(await rebuilds.value() == 0)

    await cancelGate.open()
    #expect(await waitForCondition {
        !controller.lifecycleDiagnostics.isCleanupInProgress
    })
    #expect(await waitForAsyncCondition { await rebuilds.value() == 1 })
}

@MainActor
@Test("Failed start clears its completed task ownership")
func failedStartClearsActiveStartTask() async {
    let events = LifecycleEventLog()
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: FakeMediaInterruptionService(events: events),
        coordinator: FakeDictationCoordinator(events: events, startShouldFail: true)
    )

    controller.pressToTalkStart()
    #expect(await waitForCondition { controller.status == "Failed to start" })
    #expect(!controller.lifecycleDiagnostics.hasActiveStartTask)
    controller.teardown()
}

@MainActor
@Test("Dependency cancellation during start is reported as a start failure")
func dependencyCancellationDuringStartIsReportedAsFailure() async {
    let events = LifecycleEventLog()
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: FakeMediaInterruptionService(events: events),
        coordinator: FakeDictationCoordinator(
            events: events,
            startThrowsCancellation: true
        )
    )

    controller.pressToTalkStart()

    #expect(await waitForCondition { controller.status == "Failed to start" })
    #expect(!controller.isRecording)
    #expect(!controller.lifecycleDiagnostics.hasActiveStartTask)
    controller.teardown()
}

@MainActor
@Test("A failed start applies a settings rebuild that was deferred while starting")
func failedStartAppliesDeferredSettingsRebuild() async {
    let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoTests-\(UUID().uuidString)", isDirectory: true)
    let events = LifecycleEventLog()
    let startGate = LifecycleGate()
    let rebuilds = AsyncCounter()
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: FakeMediaInterruptionService(events: events),
        preferencesStore: AppPreferencesStore(
            storageURL: testDirectory.appendingPathComponent("preferences.json")
        ),
        coordinator: FakeDictationCoordinator(
            events: events,
            startShouldFail: true,
            startGate: startGate
        ),
        runtimeRebuildOverride: {
            await rebuilds.increment()
            return FakeDictationCoordinator(events: events)
        }
    )
    defer {
        controller.teardown()
        try? FileManager.default.removeItem(at: testDirectory)
    }

    controller.pressToTalkStart()
    guard await waitForLifecycleEvent("capture.start", in: events) else {
        Issue.record("Start never reached its gate: \(await events.snapshot())")
        return
    }
    controller.applySettingsDraft(preferences: controller.preferences)
    #expect(await waitForCondition {
        controller.lifecycleDiagnostics.hasPendingRuntimeRebuild
    })

    await startGate.open()

    #expect(await waitForCondition { controller.status == "Failed to start" })
    #expect(await waitForAsyncCondition { await rebuilds.value() == 1 })
    #expect(!controller.lifecycleDiagnostics.hasPendingRuntimeRebuild)
}

private func assertCaptureCancelPrecedesMediaRelease(_ events: [String]) {
    guard let cancelIndex = events.firstIndex(of: "capture.cancel"),
          let releaseIndex = events.firstIndex(of: "media.release")
    else {
        Issue.record("Missing expected lifecycle events: \(events)")
        return
    }
    #expect(cancelIndex < releaseIndex)
}

private func assertEventOrder(_ first: String, before second: String, in events: [String]) {
    guard let firstIndex = events.firstIndex(of: first),
          let secondIndex = events.firstIndex(of: second)
    else {
        Issue.record("Missing expected lifecycle events: \(events)")
        return
    }
    #expect(firstIndex < secondIndex)
}

private actor LifecycleEventLog {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

private actor LifecycleGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor AsyncCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private enum FakeCoordinatorError: Error {
    case startFailed
    case stopFailed
}

private actor FakeDictationCoordinator: DictationSessionCoordinating {
    private let events: LifecycleEventLog
    private let startShouldFail: Bool
    private let startThrowsCancellation: Bool
    private let stopShouldFail: Bool
    private let startGate: LifecycleGate?
    private let cancelGate: LifecycleGate?
    private let processingGate: LifecycleGate?
    private let eventPrefix: String?

    init(
        events: LifecycleEventLog,
        startShouldFail: Bool = false,
        startThrowsCancellation: Bool = false,
        stopShouldFail: Bool = false,
        startGate: LifecycleGate? = nil,
        cancelGate: LifecycleGate? = nil,
        processingGate: LifecycleGate? = nil,
        eventPrefix: String? = nil
    ) {
        self.events = events
        self.startShouldFail = startShouldFail
        self.startThrowsCancellation = startThrowsCancellation
        self.stopShouldFail = stopShouldFail
        self.startGate = startGate
        self.cancelGate = cancelGate
        self.processingGate = processingGate
        self.eventPrefix = eventPrefix
    }

    func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        await events.append(event("capture.start"))
        if let startGate {
            await startGate.wait()
        }
        if startThrowsCancellation {
            throw CancellationError()
        }
        if startShouldFail {
            throw FakeCoordinatorError.startFailed
        }
        return SessionID()
    }

    func endPressToTalkCapture(sessionID: SessionID) async throws {
        await events.append(event("capture.stop"))
        if stopShouldFail {
            throw FakeCoordinatorError.stopFailed
        }
    }

    func completePressToTalk(
        sessionID: SessionID,
        languageHints: [String]
    ) async throws -> InsertResult {
        await events.append(event("transcription.start"))
        if let processingGate {
            await processingGate.wait()
        }
        return InsertResult(status: .noSpeech, method: .none, insertedText: "")
    }

    func cancel(sessionID: SessionID) async {
        await events.append(event("capture.cancel"))
        if let cancelGate {
            await cancelGate.wait()
        }
    }

    func setHandsFreeEnabled(_ enabled: Bool) async {
        await events.append(event("capture.ready"))
    }

    private func event(_ name: String) -> String {
        guard let eventPrefix else { return name }
        return "\(eventPrefix).\(name)"
    }
}

@MainActor
private final class FakeMediaInterruptionService: MediaInterruptionService {
    private let events: LifecycleEventLog

    init(events: LifecycleEventLog) {
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

private func waitForLifecycleEvent(
    _ event: String,
    in log: LifecycleEventLog,
    attempts: Int = 400
) async -> Bool {
    for _ in 0..<attempts {
        if await log.snapshot().contains(event) {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

private func waitForAnyLifecycleEvent(
    _ expectedEvents: Set<String>,
    in log: LifecycleEventLog,
    attempts: Int = 400
) async -> Bool {
    for _ in 0..<attempts {
        if !Set(await log.snapshot()).isDisjoint(with: expectedEvents) {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

private func waitForAsyncCondition(
    attempts: Int = 400,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

@MainActor
private func waitForCondition(
    attempts: Int = 400,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

@MainActor
private final class FakeHotkeyService: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?

    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16?

    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        startCount += 1
        onRegistrationStatusChanged?(.registered)
    }

    func stop() {
        stopCount += 1
    }
}
