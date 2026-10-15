import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Steno
@testable import StenoKit

/// Blocks `cancel` until released, so a cancelled recording stays "cleaning up" for as long as a
/// test needs. Everything else answers at once.
private actor SlowCancelCoordinator: DictationSessionCoordinating {
    private let cancelGate = ShortcutGate()
    private(set) var events: [String] = []

    func releaseCancel() async { await cancelGate.open() }

    func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        events.append("start")
        return SessionID()
    }

    func endPressToTalkCapture(sessionID: SessionID) async throws { events.append("end") }

    func completePressToTalk(sessionID: SessionID, languageHints: [String]) async throws -> InsertResult {
        events.append("complete")
        return InsertResult(status: .inserted, method: .direct, insertedText: "Words")
    }

    func cancel(sessionID: SessionID) async {
        events.append("cancel.requested")
        await cancelGate.wait()
        events.append("cancel.done")
    }

    func setHandsFreeEnabled(_ enabled: Bool) async {}
}

/// A Dictate click that starts nothing must not leave the window claiming a dictation it started,
/// or the next hotkey dictation reads "Stop and copy" on Today instead of "Stop and insert".
@Suite("Dictation started in the window", .serialized)
@MainActor
struct WindowStartedDictationTests {
    @Test("A Dictate click refused because the runtime is not ready leaves nothing marked as started in the window")
    func refusedWindowStartLeavesNoFlagWhenRuntimeNotReady() async throws {
        let window = try await WindowWithOptionalRuntime.make(coordinator: nil)
        defer { Task { await window.close() } }
        let controller = window.controller
        try #require(controller.microphonePermissionStatus == .granted, "probe: microphone granted")
        try #require(!controller.dictationStartedInWindow, "probe: flag starts off")

        controller.startDictationFromWindow()

        try #require(controller.status == "Runtime not ready yet.", "probe: the start was refused; status: \(controller.status)")
        try #require(controller.recordingLifecycleState == .idle, "probe: nothing is recording")
        #expect(!controller.isRecording)
        #expect(!controller.dictationStartedInWindow, "no recording began from the window, yet it is marked as started there")
    }

    @Test("A Dictate click refused because microphone access is off leaves nothing marked as started in the window")
    func refusedWindowStartLeavesNoFlagWhenMicrophoneRefused() async throws {
        let coordinator = CaptureTestCoordinator(result: InsertResult(status: .inserted, method: .direct, insertedText: "Words"))
        let window = try await WindowWithOptionalRuntime.make(coordinator: coordinator)
        defer { Task { await window.close() } }
        let controller = window.controller
        // The cached status still says granted; the live read says denied, as after the switch is turned off in Settings.
        controller.microphoneAccessProvider = { .denied }
        try #require(!controller.dictationStartedInWindow, "probe: flag starts off")

        controller.startDictationFromWindow()

        try #require(controller.status == "Microphone access is off.", "probe: the start was refused; status: \(controller.status)")
        try #require(controller.recordingLifecycleState == .idle, "probe: nothing is recording")
        #expect(!controller.dictationStartedInWindow, "no recording began from the window, yet it is marked as started there")
    }

    @Test("A Dictate click that a second click cancels while the previous recording cleans up leaves nothing marked as started in the window")
    func canceledDeferredWindowStartLeavesNoFlag() async throws {
        let coordinator = SlowCancelCoordinator()
        let window = try await WindowWithOptionalRuntime.make(coordinator: coordinator)
        defer { Task { await window.close() } }
        let controller = window.controller

        controller.toggleHandsFree()
        try #require(await eventuallyOnMain { controller.recordingLifecycleState == .recordingHandsFree }, "hands-free did not start")
        try #require(await eventuallyOnMain { await coordinator.events.contains("start") }, "capture never reached the coordinator")
        controller.cancelActiveRecording()
        try #require(await eventuallyOnMain { await coordinator.events.contains("cancel.requested") }, "the cancel never reached the coordinator")
        try #require(!controller.dictationStartedInWindow, "probe: the first (hotkey) recording was not started in the window")

        // First click: the start is deferred until the cleanup ends. Second click: it cancels that deferral.
        controller.startDictationFromWindow()
        try #require(controller.status == "Finishing the previous recording. Hands-free will start when ready.",
                     "probe: the first click was deferred; status: \(controller.status)")
        controller.startDictationFromWindow()
        try #require(controller.status == "Deferred hands-free start canceled.",
                     "probe: the second click canceled the deferral; status: \(controller.status)")

        let whileCleaning = controller.dictationStartedInWindow
        await coordinator.releaseCancel()
        try #require(await eventuallyOnMain { await coordinator.events.contains("cancel.done") })
        try await Task.sleep(for: .milliseconds(300))
        try #require(controller.recordingLifecycleState == .idle, "probe: the canceled deferral started nothing")
        #expect(!whileCleaning, "during the cleanup, with the deferred start canceled, nothing is going to start from the window")
        #expect(!controller.dictationStartedInWindow, "after the cleanup, with no recording, the window still claims one")
    }

    @Test("A Dictate click ignored while a dictation is transcribing leaves nothing marked as started in the window")
    func ignoredWindowStartWhileTranscribingLeavesNoFlag() async throws {
        let session = try await WindowDictation.make()
        defer { Task { await session.close() } }
        let controller = session.controller

        await session.coordinator.hold()
        controller.toggleHandsFree()
        try #require(await eventuallyOnMain { controller.recordingLifecycleState == .recordingHandsFree }, "hands-free did not start")
        try #require(await eventuallyOnMain { await session.coordinator.count("start") == 1 }, "capture never reached the coordinator")
        controller.stopRecording()
        try #require(await eventuallyOnMain { controller.recordingLifecycleState == .transcribing }, "Stop did not reach Transcribing")

        controller.startDictationFromWindow()

        try #require(controller.status == "Still finishing the previous dictation. Try again when it is done.",
                     "probe: the click was ignored; status: \(controller.status)")
        #expect(!controller.dictationStartedInWindow, "nothing began from the window, yet it is marked as started there")
        await session.coordinator.release()
        #expect(await eventuallyOnMain { controller.recordingLifecycleState == .idle })
    }

    @Test("A Dictate click deferred while the previous recording cleans up is marked as started in the window once it starts")
    func deferredWindowStartThatProceedsKeepsTheFlag() async throws {
        let coordinator = SlowCancelCoordinator()
        let window = try await WindowWithOptionalRuntime.make(coordinator: coordinator)
        defer { Task { await window.close() } }
        let controller = window.controller

        controller.toggleHandsFree()
        try #require(await eventuallyOnMain { controller.recordingLifecycleState == .recordingHandsFree }, "hands-free did not start")
        try #require(await eventuallyOnMain { await coordinator.events.contains("start") }, "capture never reached the coordinator")
        controller.cancelActiveRecording()
        try #require(await eventuallyOnMain { await coordinator.events.contains("cancel.requested") }, "the cancel never reached the coordinator")

        controller.startDictationFromWindow()
        try #require(controller.status == "Finishing the previous recording. Hands-free will start when ready.",
                     "probe: the click was deferred; status: \(controller.status)")
        #expect(controller.dictationStartedInWindow, "a start that is going to happen from the window is not marked")
        await coordinator.releaseCancel()

        try #require(await eventuallyOnMain { controller.recordingLifecycleState == .recordingHandsFree }, "the deferred start never began")
        #expect(controller.dictationStartedInWindow)
    }

    // MARK: - What Today shows

    private func todayHost(_ controller: DictationController) -> TransitionHost {
        let feedback = GroveFeedback()
        feedback.announce = { _ in }
        let flow = GroveTodayFlow(timing: .init(resultWait: .seconds(60), settleHold: .seconds(3), quietNote: .seconds(3)))
        return TransitionHost(controller: controller) {
            GroveRenderHarness.window(.today, controller: controller, feedback: feedback) { GroveTodayView(flow: flow) }
        }
    }

    private func says(_ host: TransitionHost, containing fragment: String) -> Bool {
        host.node { $0.text.contains(fragment) || $0.name.contains(fragment) } != nil
    }

    /// Clicks Dictate on Today while no runtime is available, then brings a runtime up.
    private func refusedClickThenRuntime(_ window: WindowWithOptionalRuntime, _ host: TransitionHost) async throws -> ScriptedCoordinator {
        await host.settle { host.node(identifier: "today.start") != nil }
        try await host.press("Dictate")
        try #require(window.controller.status == "Runtime not ready yet.", "probe: the click was refused; status: \(window.controller.status)")
        try #require(window.controller.recordingLifecycleState == .idle, "probe: nothing is recording")
        let coordinator = ScriptedCoordinator(history: window.history, outcome: .init(text: "Agenda attached.", status: .inserted))
        window.controller.replaceCoordinatorForLifecycleTesting(coordinator)
        return coordinator
    }

    @Test("After a refused Dictate click, the hands-free key pressed in another app shows Today a dictation going to that app")
    func handsFreeKeyAfterRefusedClickIsLabelledAsInserting() async throws {
        let window = try await WindowWithOptionalRuntime.make(coordinator: nil)
        defer { Task { await window.close() } }
        let host = todayHost(window.controller)
        defer { host.close() }
        let coordinator = try await refusedClickThenRuntime(window, host)

        window.hotkey.onToggleHandsFree?()
        try #require(await host.settle { window.controller.recordingLifecycleState == .recordingHandsFree },
                     "probe: the key started a dictation; status: \(window.controller.status)")
        try #require(await eventuallyOnMain { await coordinator.count("start") == 1 }, "probe: capture started")
        #expect(await host.settle { says(host, containing: "Listening") }, "no Listening plate: \(host.names())")
        // The plate's " · copied when you stop" line is hidden from accessibility, so the Stop button's name
        // (drawn from the same flag as that line) is what shows which destination Today claims.
        #expect(host.node(named: "Stop and copy") == nil, "Stop is named “Stop and copy” for a dictation inserted into the front app: \(host.names())")
        #expect(host.node(named: "Stop and insert") != nil, "no “Stop and insert”: \(host.names())")
    }

    @Test("After a refused Dictate click, holding Option in another app shows Today a dictation going to that app")
    func optionHoldAfterRefusedClickIsLabelledAsInserting() async throws {
        let window = try await WindowWithOptionalRuntime.make(coordinator: nil)
        defer { Task { await window.close() } }
        let host = todayHost(window.controller)
        defer { host.close() }
        let coordinator = try await refusedClickThenRuntime(window, host)

        window.hotkey.onPressToTalkStart?()
        try #require(await host.settle { window.controller.recordingLifecycleState == .recordingPressToTalk },
                     "probe: Option started a dictation; status: \(window.controller.status)")
        try #require(await eventuallyOnMain { await coordinator.count("start") == 1 }, "probe: capture started")
        #expect(await host.settle { says(host, containing: "Listening") }, "no Listening plate: \(host.names())")
        #expect(host.node(named: "Stop and copy") == nil, "Stop is named “Stop and copy” for a dictation inserted into the front app: \(host.names())")
        #expect(host.node(named: "Stop and insert") != nil, "no “Stop and insert”: \(host.names())")
    }
}
