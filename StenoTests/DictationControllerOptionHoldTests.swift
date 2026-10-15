import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

/// The Option key as the system reports it, switched by the test.
@MainActor
private final class OptionKeyReader {
    var isHeld: Bool
    private(set) var reads = 0
    init(isHeld: Bool) { self.isHeld = isHeld }
    func read() -> Bool {
        reads += 1
        return isHeld
    }
}

/// A second controller whose Option stays down and which records press-to-talk. Its missed-release
/// check reads the key every 500 ms on the same main-actor clock as the controller under test, so
/// waiting for N of its reads proves N watchdog periods also elapsed for the other controller,
/// however loaded the machine is. A bare sleep could pass vacuously.
@MainActor
private final class WatchdogClock {
    let option = OptionKeyReader(isHeld: true)
    let events = MediaReleaseEventLog()
    let controller: DictationController

    init() {
        let option = option
        controller = makeTestDictationController(
            hotkey: MediaReleaseHotkeyService(),
            coordinator: MediaReleaseCoordinator(events: events),
            isOptionHeld: { option.read() })
    }

    func start() async -> Bool {
        controller.pressToTalkStart()
        return await eventuallyOnMain { self.controller.isRecording }
    }

    /// True once the clock controller's check has read the key `periods` more times.
    func waitForPeriods(_ periods: Int) async -> Bool {
        let base = option.reads
        return await eventuallyOnMain { self.option.reads >= base + periods }
    }

    func finish() async {
        controller.pressToTalkStop()
        _ = await events.waitForCount("transcription.start", 1)
        await controller.teardownAndWait()
    }
}

@MainActor
private func pollOnMain(seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
@Suite("DictationControllerOptionHoldTests", .serialized)
struct DictationControllerOptionHoldTests {
    /// 6 periods = 3 s; a stop needs only 2 readings without Option.
    private let periods = 6

    private func make(_ option: OptionKeyReader, _ events: MediaReleaseEventLog) -> DictationController {
        makeTestDictationController(
            hotkey: MediaReleaseHotkeyService(),
            coordinator: MediaReleaseCoordinator(events: events),
            isOptionHeld: { option.read() })
    }

    @Test("A hands-free dictation from the global key is never ended by the Option watchdog", arguments: [false, true])
    func handsFreeKeyIgnoresWatchdog(optionHeldAtStart: Bool) async throws {
        let clock = WatchdogClock()
        try #require(await clock.start(), "the clock controller never started recording")
        let option = OptionKeyReader(isHeld: optionHeldAtStart)
        let events = MediaReleaseEventLog()
        let controller = make(option, events)

        controller.toggleHandsFree()
        try #require(await eventuallyOnMain { controller.isRecording }, "hands-free never started")
        try #require(controller.recordingLifecycleState == .recordingHandsFree)
        option.isHeld = false
        try #require(await clock.waitForPeriods(periods), "the clock never advanced")

        #expect(controller.recordingLifecycleState == .recordingHandsFree, "the watchdog ended a hands-free dictation")
        #expect(controller.isRecording)
        #expect(events.count("transcription.start") == 0, "\(events.names())")
        #expect(events.count("capture.stop") == 0)
        controller.stopRecording()
        #expect(await events.waitForCount("transcription.start", 1))
        await controller.teardownAndWait()
        await clock.finish()
    }

    @Test("A dictation started from the window is never ended by the Option watchdog", arguments: [false, true])
    func windowDictationIgnoresWatchdog(optionHeldAtStart: Bool) async throws {
        let clock = WatchdogClock()
        try #require(await clock.start(), "the clock controller never started recording")
        let option = OptionKeyReader(isHeld: optionHeldAtStart)
        let events = MediaReleaseEventLog()
        let controller = make(option, events)
        controller.microphonePermissionStatus = .granted

        controller.startDictationFromWindow()
        try #require(await eventuallyOnMain { controller.isRecording }, "the window dictation never started")
        try #require(controller.recordingLifecycleState == .recordingHandsFree)
        try #require(controller.dictationStartedInWindow)
        option.isHeld = false
        try #require(await clock.waitForPeriods(periods), "the clock never advanced")

        #expect(controller.recordingLifecycleState == .recordingHandsFree, "the watchdog ended a window dictation")
        #expect(controller.dictationStartedInWindow)
        #expect(events.count("transcription.start") == 0, "\(events.names())")
        controller.stopRecording()
        #expect(await events.waitForCount("transcription.start", 1))
        await controller.teardownAndWait()
        await clock.finish()
    }


    enum EndOfA: String, CaseIterable, Sendable { case stop, cancel }

    @Test("A finished Option dictation's watchdog cannot end the next dictation", arguments: EndOfA.allCases)
    func staleWatchdogCannotEndNextSession(_ endOfA: EndOfA) async throws {
        let clock = WatchdogClock()
        try #require(await clock.start(), "the clock controller never started recording")
        let option = OptionKeyReader(isHeld: true)
        let events = MediaReleaseEventLog()
        let controller = make(option, events)

        controller.pressToTalkStart()
        try #require(await eventuallyOnMain { controller.isRecording }, "A never started")
        option.isHeld = false
        switch endOfA {
        case .stop:
            controller.pressToTalkStop()
            try #require(await events.waitForCount("transcription.start", 1))
            try #require(await waitForIdle(controller))
        case .cancel:
            controller.cancelActiveRecording()
            try #require(await waitForIdle(controller))
            try #require(await eventuallyOnMain { !controller.lifecycleDiagnostics.isCleanupInProgress })
        }
        controller.toggleHandsFree()
        try #require(await eventuallyOnMain { controller.isRecording }, "B never started")
        try #require(controller.recordingLifecycleState == .recordingHandsFree)
        try #require(await clock.waitForPeriods(periods), "the clock never advanced")

        #expect(controller.recordingLifecycleState == .recordingHandsFree, "A's watchdog ended B")
        #expect(events.count("transcription.start") == (endOfA == .stop ? 1 : 0), "\(events.names())")
        controller.stopRecording()
        await controller.teardownAndWait()
        await clock.finish()
    }

    @Test("An Option dictation is not ended early by a previous dictation's missed-release readings")
    func staleReadingsDoNotCarryOver() async throws {
        let clock = WatchdogClock()
        try #require(await clock.start(), "the clock controller never started recording")
        let option = OptionKeyReader(isHeld: true)
        let events = MediaReleaseEventLog()
        let controller = make(option, events)

        controller.pressToTalkStart()
        try #require(await eventuallyOnMain { controller.isRecording }, "A never started")
        option.isHeld = false
        let before = option.reads
        try #require(await eventuallyOnMain { option.reads >= before + 1 })
        controller.pressToTalkStop()
        try #require(await waitForIdle(controller))
        option.isHeld = true
        controller.pressToTalkStart()
        try #require(await eventuallyOnMain { controller.isRecording }, "B never started")
        try #require(await clock.waitForPeriods(periods), "the clock never advanced")

        #expect(controller.recordingLifecycleState == .recordingPressToTalk, "B was stopped on A's reading")
        #expect(events.count("transcription.start") == 1, "\(events.names())")
        option.isHeld = false
        #expect(await events.waitForCount("transcription.start", 2))
        await controller.teardownAndWait()
        await clock.finish()
    }

    @Test("With pausing off for press to talk, Option held alone is presented as a recording once confirmed")
    func optionHoldWithMediaPausingOffIsPresented() async throws {
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
        controller.preferences.media.pauseDuringPressToTalk = false
        try #require(!controller.preferences.media.pauseDuringPressToTalk)

        hotkey.press([.option])
        try #require(await waitForShortcutEvent("capture.start", in: events))
        // Real timing: capture is up and the start task has finished before the 0.15 s confirmation.
        // With pausing off the start task does not wait on the press, so this settles.
        try #require(await waitForShortcutCondition { !controller.lifecycleDiagnostics.hasActiveStartTask },
                     "the start task never finished")
        try #require(controller.recordingLifecycleState == .recordingPressToTalk)
        try #require(!controller.isRecording)
        try #require(!presenter.hostedEvidenceShownStates().contains { $0.isListening })

        hotkey.holdPastConfirmationWindow()
        let isRecording = await pollOnMain(seconds: 5) { controller.isRecording }
        let startedAt = await pollOnMain(seconds: 1) { controller.recordingStartedAt != nil }
        let listening = await pollOnMain(seconds: 1) { presenter.hostedEvidenceShownStates().contains { $0.isListening } }
        #expect(isRecording, "isRecording stayed false after the press was confirmed")
        #expect(startedAt, "recordingStartedAt stayed nil after the press was confirmed")
        #expect(listening, "the island never showed the listening state: \(presenter.hostedEvidenceShownStates())")
        #expect(controller.status == "Recording...", "status was \(controller.status)")

        hotkey.press([])
        #expect(await waitForShortcutEvent("transcription.start", in: events))
        await controller.teardownAndWait()
    }

    // The same press with media pausing on.
    @Test("With pausing on for press to talk, Option held alone is presented as a recording once confirmed")
    func optionHoldWithMediaPausingOnIsPresented() async throws {
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
        try #require(controller.preferences.media.pauseDuringPressToTalk)

        hotkey.press([.option])
        try #require(await waitForShortcutEvent("capture.start", in: events))
        try #require(!controller.isRecording)

        hotkey.holdPastConfirmationWindow()
        let isRecording = await pollOnMain(seconds: 5) { controller.isRecording }
        let startedAt = await pollOnMain(seconds: 1) { controller.recordingStartedAt != nil }
        let listening = await pollOnMain(seconds: 1) { presenter.hostedEvidenceShownStates().contains { $0.isListening } }
        #expect(isRecording)
        #expect(startedAt)
        #expect(listening)

        hotkey.press([])
        #expect(await waitForShortcutEvent("transcription.start", in: events))
        await controller.teardownAndWait()
    }
}
