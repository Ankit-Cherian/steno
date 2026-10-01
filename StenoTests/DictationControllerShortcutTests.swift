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
@Test("A saved Disabled hands-free key shows no error at launch")
func savedDisabledHandsFreeKeyShowsNoErrorAtLaunch() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoDisabledKeyLaunch-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storageURL = directory.appendingPathComponent("preferences.json")
    var saved = AppPreferences.default
    saved.hotkeys.handsFreeGlobalKeyCode = nil
    #expect((try? await AppPreferencesStore(storageURL: storageURL).save(saved).get()) != nil)
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: storageURL)) as? [String: Any]
    )
    let hotkeys = try #require(object["hotkeys"] as? [String: Any])
    #expect(hotkeys["handsFreeGlobalKeyCode"] is NSNull)

    let presenter = makeShortcutTestPresenter()
    let hotkey = MacHotkeyMonitor()
    let controller = makeTestDictationController(
        hotkey: hotkey,
        overlay: presenter,
        preferencesStore: AppPreferencesStore(storageURL: storageURL)
    )
    defer { controller.teardown() }

    var reportedStatuses: [HotkeyRegistrationStatus] = []
    let controllerHandler = hotkey.onRegistrationStatusChanged
    hotkey.onRegistrationStatusChanged = { status in
        reportedStatuses.append(status)
        controllerHandler?(status)
    }

    // The app's initializer starts the monitor before saved preferences load;
    // the isolated fixture skips that, so it is replayed here.
    hotkey.start()
    await controller.bootstrap()
    #expect(await waitForShortcutCondition { controller.hasBootstrapped })

    // A key the user turned off is never registered, so a Mac where the
    // listener can't be installed has nothing to report either.
    #expect(reportedStatuses == [.disabled])

    #expect(controller.preferences.hotkeys.handsFreeGlobalKeyCode == nil)
    #expect(controller.hotkeyRegistrationMessage.isEmpty)
    #expect(controller.lastError.isEmpty)
    #expect(controller.storageNotice == nil)
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

// MARK: - Option shortcuts

@MainActor
@Test("Option held alone starts capture at once and shows the overlay and pauses media only after confirmation")
func optionHeldAloneDictates() async {
    let events = ShortcutEventLog()
    let presenter = makeShortcutTestPresenter()
    let hotkey = FilteringHotkeyService()
    let controller = makeTestDictationController(
        hotkey: hotkey,
        overlay: presenter,
        mediaInterruption: ShortcutTestMediaService(events: events),
        coordinator: ShortcutTestCoordinator(events: events)
    )
    defer { controller.teardown() }

    hotkey.press([.option])
    // Capture must not wait for the confirmation window.
    #expect(await waitForShortcutEvent("capture.start", in: events))
    try? await Task.sleep(for: .milliseconds(100))
    #expect(await events.count(of: "media.pause") == 0)
    #expect(!presenter.hostedEvidenceShownStates().contains { $0.isListening })
    #expect(!controller.isRecording)

    hotkey.holdPastConfirmationWindow()
    #expect(await waitForShortcutEvent("media.pause", in: events))
    #expect(await waitForShortcutCondition { presenter.hostedEvidenceShownStates().contains { $0.isListening } })
    let startEvents = await events.snapshot()
    #expect(startEvents.firstIndex(of: "capture.start") ?? .max < startEvents.firstIndex(of: "media.pause") ?? .min)

    hotkey.press([])
    #expect(await waitForShortcutEvent("transcription.start", in: events))
    #expect(await waitForShortcutCondition { controller.lastTranscript == "Nearby words" })
    #expect(await events.count(of: "capture.cancel") == 0)
}

@MainActor
@Test(
    "Keyboard shortcuts that use Option show no overlay, insert nothing, and leave media alone",
    arguments: OptionShortcut.allCases
)
func optionShortcutsAreDiscarded(_ shortcut: OptionShortcut) async {
    let events = ShortcutEventLog()
    let presenter = makeShortcutTestPresenter()
    let hotkey = FilteringHotkeyService()
    let controller = makeTestDictationController(
        hotkey: hotkey,
        overlay: presenter,
        mediaInterruption: ShortcutTestMediaService(events: events),
        coordinator: ShortcutTestCoordinator(events: events)
    )
    defer { controller.teardown() }
    controller.status = "Ready"

    shortcut.perform(on: hotkey)

    // A discard can arrive before capture starts; any capture that did start is canceled.
    #expect(await waitForShortcutCondition {
        controller.recordingLifecycleState == .idle
            && !controller.lifecycleDiagnostics.isCleanupInProgress
            && !controller.lifecycleDiagnostics.hasActiveStartTask
    })
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await waitForShortcutCondition {
        await events.count(of: "capture.start") == events.count(of: "capture.cancel")
    })
    let recorded = await events.snapshot()
    if !shortcut.startsCapture {
        #expect(!recorded.contains("capture.start"), "\(shortcut): \(recorded)")
    }
    #expect(!recorded.contains("transcription.start"), "\(shortcut): \(recorded)")
    #expect(!recorded.contains("media.pause"), "\(shortcut): \(recorded)")
    #expect(presenter.hostedEvidenceShownStates().isEmpty, "\(shortcut)")
    #expect(controller.lastTranscript.isEmpty)
    #expect(controller.status == "Ready")
    #expect(!controller.isRecording)
    await controller.refreshHistory()
    #expect(controller.recentEntries.isEmpty)
}

@MainActor
@Test("A key pressed after the confirmation window cancels the recording and restores media")
func lateShortcutKeyCancelsRecording() async {
    let events = ShortcutEventLog()
    let presenter = makeShortcutTestPresenter()
    let hotkey = FilteringHotkeyService()
    let controller = makeTestDictationController(
        hotkey: hotkey,
        overlay: presenter,
        mediaInterruption: ShortcutTestMediaService(events: events),
        coordinator: ShortcutTestCoordinator(events: events)
    )
    defer { controller.teardown() }

    // Option+L types @ on many non-US layouts, and the key can follow a pause.
    hotkey.press([.option])
    hotkey.holdPastConfirmationWindow()
    #expect(await waitForShortcutEvent("media.pause", in: events))
    #expect(await waitForShortcutCondition { controller.isRecording })
    hotkey.keyDown(after: 0.1)
    hotkey.press([], after: 0.05)

    #expect(await waitForShortcutEvent("media.release", in: events))
    #expect(await waitForShortcutEvent("capture.cancel", in: events))
    #expect(await waitForShortcutCondition {
        controller.recordingLifecycleState == .idle
            && !controller.lifecycleDiagnostics.isCleanupInProgress
    })
    #expect(await events.count(of: "transcription.start") == 0)
    #expect(!controller.isRecording)
    #expect(controller.lastTranscript.isEmpty)
    #expect(controller.status == "Recording canceled.")
}

@MainActor
@Test("A real Option hold straight after a shortcut still dictates")
func optionHoldAfterShortcutDictates() async {
    let events = ShortcutEventLog()
    let hotkey = FilteringHotkeyService()
    let controller = makeTestDictationController(
        hotkey: hotkey,
        overlay: makeShortcutTestPresenter(),
        mediaInterruption: ShortcutTestMediaService(events: events),
        coordinator: ShortcutTestCoordinator(events: events)
    )
    defer { controller.teardown() }

    OptionShortcut.optionArrow.perform(on: hotkey)
    // Pressed while the shortcut's recording is still being thrown away.
    hotkey.press([.option])
    hotkey.holdPastConfirmationWindow()
    #expect(await waitForShortcutCondition { controller.isRecording })
    hotkey.press([])

    #expect(await waitForShortcutEvent("transcription.start", in: events))
    #expect(await events.count(of: "transcription.start") == 1)
    #expect(await waitForShortcutCondition { controller.lastTranscript == "Nearby words" })
}

@MainActor
@Test("An Option shortcut during hands-free recording leaves the recording running")
func optionShortcutLeavesHandsFreeRunning() async {
    let events = ShortcutEventLog()
    let hotkey = FilteringHotkeyService()
    let controller = makeTestDictationController(
        hotkey: hotkey,
        overlay: makeShortcutTestPresenter(),
        coordinator: ShortcutTestCoordinator(events: events)
    )
    defer { controller.teardown() }

    controller.toggleHandsFree()
    #expect(await waitForShortcutCondition { controller.isRecording })
    OptionShortcut.optionArrow.perform(on: hotkey)
    try? await Task.sleep(for: .milliseconds(100))

    #expect(controller.recordingLifecycleState == .recordingHandsFree)
    #expect(await events.count(of: "capture.cancel") == 0)
}

// MARK: - Presses while the previous dictation finishes

@MainActor
@Test("A press while the previous dictation is finishing shows a cue, but an Option shortcut stays silent")
func pressWhileFinishingShowsCue() async {
    let events = ShortcutEventLog()
    let gate = ShortcutGate()
    let presenter = makeShortcutTestPresenter()
    let hotkey = FilteringHotkeyService()
    let controller = makeTestDictationController(
        hotkey: hotkey,
        overlay: presenter,
        coordinator: ShortcutTestCoordinator(events: events, completionGate: gate)
    )
    defer { controller.teardown() }
    let notice = "Still finishing. Try again."
    func overlayText() -> String? { presenter.hostedEvidenceUserFacingStrings().first }

    hotkey.press([.option])
    hotkey.holdPastConfirmationWindow()
    #expect(await waitForShortcutCondition { controller.isRecording })
    hotkey.press([])
    #expect(await waitForShortcutEvent("transcription.start", in: events))
    #expect(controller.recordingLifecycleState == .transcribing)
    #expect(overlayText() == "Transcribing...")

    OptionShortcut.optionArrow.perform(on: hotkey)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(overlayText() == "Transcribing...")

    hotkey.press([.option])
    #expect(overlayText() == "Transcribing...")
    hotkey.holdPastConfirmationWindow()
    #expect(overlayText() == notice)
    #expect(controller.status.hasPrefix("Still finishing the previous dictation."))
    hotkey.press([])
    #expect(await waitForShortcutCondition(attempts: 1_000) { overlayText() == "Transcribing..." })

    controller.toggleHandsFree()
    #expect(overlayText() == notice)

    await gate.open()
    #expect(await waitForShortcutCondition { controller.recordingLifecycleState == .idle })
    #expect(await events.count(of: "transcription.start") == 1)
    #expect(await events.count(of: "capture.start") == 1)
}

// MARK: - Recording length

@MainActor
@Test("A recording that reaches the length limit warns first, then stops and is transcribed", arguments: [false, true])
func recordingLimitStopsAndTranscribes(handsFree: Bool) async {
    let events = ShortcutEventLog()
    let presenter = makeShortcutTestPresenter()
    let hotkey = FilteringHotkeyService()
    let controller = makeTestDictationController(
        hotkey: hotkey,
        overlay: presenter,
        coordinator: ShortcutTestCoordinator(events: events)
    )
    defer { controller.teardown() }
    controller.recordingDurationLimit = RecordingDurationLimit(maximumSeconds: 3, warningLeadSeconds: 2)

    if handsFree {
        controller.toggleHandsFree()
    } else {
        // Option stays held: the limit, not a key-up, ends this recording.
        hotkey.press([.option])
        hotkey.holdPastConfirmationWindow()
    }
    #expect(await waitForShortcutCondition { controller.isRecording })

    #expect(await waitForShortcutCondition(attempts: 1_000) {
        presenter.hostedEvidenceUserFacingStrings().first?.hasPrefix("Stops in") == true
    })
    #expect(controller.status == "Recording stops automatically in one minute.")
    #expect(await waitForShortcutEvent("transcription.start", in: events, attempts: 1_000))
    #expect(await waitForShortcutCondition { controller.lastTranscript == "Nearby words" })
    #expect(await events.count(of: "capture.cancel") == 0)

    if !handsFree {
        // The late key-up belongs to a press that has already finished.
        hotkey.press([])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await events.count(of: "transcription.start") == 1)
    }
}

enum OptionShortcut: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case optionArrow
    case optionDelete
    case commandOptionI
    case optionThenCommand
    case quickOptionTap

    var testDescription: String { rawValue }

    /// Whether capture starts before the press is recognized as a shortcut.
    var startsCapture: Bool { self != .commandOptionI }

    @MainActor
    func perform(on hotkey: FilteringHotkeyService) {
        switch self {
        case .optionArrow, .optionDelete:
            hotkey.press([.option])
            hotkey.keyDown(after: 0.06)
            hotkey.press([], after: 0.05)
        case .commandOptionI:
            hotkey.press([.command])
            hotkey.press([.command, .option], after: 0.04)
            hotkey.keyDown(after: 0.05)
            hotkey.press([.command], after: 0.05)
            hotkey.press([], after: 0.02)
        case .optionThenCommand:
            hotkey.press([.option])
            hotkey.press([.option, .command], after: 0.05)
            hotkey.keyDown(after: 0.03)
            hotkey.press([.command], after: 0.05)
            hotkey.press([], after: 0.02)
        case .quickOptionTap:
            hotkey.press([.option])
            hotkey.press([], after: 0.08)
        }
    }
}

/// Drives the production press-to-talk filter with scripted key events on a
/// virtual clock, and forwards its decisions the way `MacHotkeyMonitor` does.
@MainActor
final class FilteringHotkeyService: HotkeyService {
    let confirmsPressToTalk = true
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkConfirmed: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onPressToTalkDiscarded: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?

    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16?

    private var filter = PressToTalkKeyFilter()
    private var now: TimeInterval = 1_000

    func start() {}
    func stop() {}

    func press(_ modifiers: PressToTalkKeyFilter.Modifiers, after seconds: TimeInterval = 0) {
        send(.modifiersChanged(modifiers), after: seconds)
    }

    func keyDown(after seconds: TimeInterval = 0) {
        send(.keyDown, after: seconds)
    }

    func holdPastConfirmationWindow() {
        send(.confirmationDeadline, after: filter.confirmationDelay)
    }

    private func send(_ input: PressToTalkKeyFilter.Input, after seconds: TimeInterval) {
        now += seconds
        for action in filter.handle(input, at: now) {
            switch action {
            case .start: onPressToTalkStart?()
            case .confirm: onPressToTalkConfirmed?()
            case .stop: onPressToTalkStop?()
            case .discard: onPressToTalkDiscarded?()
            }
        }
    }
}

// MARK: - Helpers

func waitForShortcutEvent(
    _ event: String,
    in log: ShortcutEventLog,
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

actor ShortcutGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

actor ShortcutTestCoordinator: DictationSessionCoordinating {
    private let events: ShortcutEventLog
    private let transcript: String
    private let completionGate: ShortcutGate?

    init(
        events: ShortcutEventLog,
        transcript: String = "Nearby words",
        completionGate: ShortcutGate? = nil
    ) {
        self.events = events
        self.transcript = transcript
        self.completionGate = completionGate
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
        await completionGate?.wait()
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
