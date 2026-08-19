import AppKit
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
@Test("Hands-free starts capture before checking media")
func handsFreeStartsCaptureBeforeCheckingMedia() async {
    let events = LifecycleEventLog()
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: FakeMediaInterruptionService(events: events),
        coordinator: FakeDictationCoordinator(events: events)
    )

    controller.toggleHandsFree()
    guard await waitForLifecycleEvent("media.pause", in: events) else {
        Issue.record("Start events: \(await events.snapshot()); status: \(controller.status)")
        controller.teardown()
        return
    }

    assertEventOrder("capture.start", before: "media.pause", in: await events.snapshot())
    controller.teardown()
}

@MainActor
@Test("Normal stop closes the capture before media ownership releases")
func normalStopClosesCaptureBeforeMediaRelease() async {
    let events = LifecycleEventLog()
    let stopEntryGate = LifecycleGate()
    let coordinator = FakeDictationCoordinator(
        events: events,
        stopEntryGate: stopEntryGate
    )
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
    guard await waitForLifecycleEvent("capture.stop.waiting", in: events) else {
        Issue.record("Capture stop never reached its gate: \(await events.snapshot())")
        controller.teardown()
        return
    }
    #expect(!(await waitForLifecycleEvent("media.release", in: events, attempts: 20)))
    await stopEntryGate.open()
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
    await controller.teardownAndWait()

    #expect(await waitForLifecycleEvent("capture.cancel", in: events))
    #expect(await waitForLifecycleEvent("runtime.shutdown", in: events))
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(controller.status == statusAtTeardown)
    #expect((await events.snapshot()).filter { $0 == "media.release" }.count == 1)
    #expect((await events.snapshot()).filter { $0 == "runtime.shutdown" }.count == 1)
}

@MainActor
@Test("Explicit cancel during transcription emits no late completion")
func explicitCancelDuringTranscriptionEmitsNoLateCompletion() async {
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
        await controller.teardownAndWait()
        return
    }
    controller.pressToTalkStop()
    guard await waitForLifecycleEvent("transcription.start", in: events),
          await waitForLifecycleEvent("media.release", in: events)
    else {
        Issue.record("Processing events: \(await events.snapshot()); status: \(controller.status)")
        await controller.teardownAndWait()
        return
    }

    controller.cancelActiveRecording()
    let statusAtCancel = controller.status
    await processingGate.open()

    #expect(await waitForLifecycleEvent("capture.cancel", in: events))
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(controller.recordingLifecycleState == .idle)
    #expect(controller.status == statusAtCancel)
    #expect(controller.lastTranscript.isEmpty)
    #expect((await events.snapshot()).filter { $0 == "media.release" }.count == 1)
    await controller.teardownAndWait()
}

@MainActor
@Test("System unload waits for canceled and newer completion tasks")
func systemUnloadWaitsForAllCompletionTasks() async {
    let events = LifecycleEventLog()
    let oldGate = LifecycleGate()
    let newGate = LifecycleGate()
    let unloadCompletions = AsyncCounter()
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: FakeMediaInterruptionService(events: events),
        coordinator: FakeDictationCoordinator(
            events: events,
            processingGates: [oldGate, newGate]
        )
    )

    controller.pressToTalkStart()
    guard await waitForLifecycleEventCount("capture.ready", count: 1, in: events) else {
        Issue.record("First start did not settle: \(await events.snapshot())")
        await controller.teardownAndWait()
        return
    }
    controller.pressToTalkStop()
    guard await waitForLifecycleEventCount("transcription.start", count: 1, in: events) else {
        Issue.record("First completion did not start: \(await events.snapshot())")
        await controller.teardownAndWait()
        return
    }

    controller.cancelActiveRecording()
    controller.pressToTalkStart()
    guard await waitForLifecycleEventCount("capture.ready", count: 2, in: events) else {
        Issue.record("Rapid restart did not settle: \(await events.snapshot())")
        await controller.teardownAndWait()
        return
    }
    controller.pressToTalkStop()
    guard await waitForLifecycleEventCount("transcription.start", count: 2, in: events) else {
        Issue.record("Newer completion did not start: \(await events.snapshot())")
        await controller.teardownAndWait()
        return
    }

    let unloadTask = Task {
        await controller.unloadRuntimeForLifecycleTesting()
        await unloadCompletions.increment()
    }
    for _ in 0..<20 {
        await Task.yield()
    }
    #expect(await unloadCompletions.value() == 0)
    #expect(!(await events.snapshot()).contains("runtime.unload"))

    await oldGate.open()
    for _ in 0..<20 {
        await Task.yield()
    }
    #expect(await unloadCompletions.value() == 0)

    await newGate.open()
    await unloadTask.value

    let statusAfterUnload = controller.status
    try? await Task.sleep(nanoseconds: 20_000_000)
    #expect(await unloadCompletions.value() == 1)
    #expect((await events.snapshot()).filter { $0 == "runtime.unload" }.count == 1)
    #expect(controller.status == statusAfterUnload)
    #expect(controller.recordingLifecycleState == .idle)
    await controller.teardownAndWait()
}

@MainActor
@Test("A terminal overlay dismissal cannot hide a rapidly restarted session")
func staleOverlayDismissalCannotHideRapidRestart() async {
    let events = LifecycleEventLog()
    let dismissDelay = LifecycleGate()
    let dismissRecorder = OverlayDismissActionRecorder()
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: FakeMediaInterruptionService(events: events),
        coordinator: FakeDictationCoordinator(events: events),
        overlayDismissDelay: {
            await dismissDelay.wait()
        },
        overlayDismissAction: {
            dismissRecorder.dismiss()
        }
    )

    controller.pressToTalkStart()
    guard await waitForLifecycleEventCount("capture.ready", count: 1, in: events) else {
        Issue.record("First start did not settle: \(await events.snapshot())")
        await controller.teardownAndWait()
        return
    }
    controller.pressToTalkStop()
    guard await waitForCondition({ controller.recordingLifecycleState == .idle }) else {
        Issue.record("First completion did not settle: \(await events.snapshot())")
        await controller.teardownAndWait()
        return
    }

    controller.pressToTalkStart()
    guard await waitForLifecycleEventCount("capture.ready", count: 2, in: events) else {
        Issue.record("Rapid restart did not settle: \(await events.snapshot())")
        await controller.teardownAndWait()
        return
    }

    await dismissDelay.open()
    for _ in 0..<20 {
        await Task.yield()
    }

    #expect(controller.recordingLifecycleState == .recordingPressToTalk)
    #expect(controller.isRecording)
    #expect(dismissRecorder.dismissCount == 0)
    controller.cancelActiveRecording()
    await controller.teardownAndWait()
}

@MainActor
@Test("Memory pressure defers runtime unload until press-to-talk finishes")
func memoryPressureCannotReleaseMediaDuringPressToTalk() async {
    let events = LifecycleEventLog()
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: FakeMediaInterruptionService(events: events),
        coordinator: FakeDictationCoordinator(events: events)
    )

    controller.pressToTalkStart()
    guard await waitForLifecycleEvent("capture.ready", in: events),
          await waitForLifecycleEvent("media.pause", in: events)
    else {
        Issue.record("Start did not settle: \(await events.snapshot())")
        await controller.teardownAndWait()
        return
    }

    await controller.unloadRuntimeForMemoryPressureTesting()

    let beforeStop = await events.snapshot()
    #expect(controller.isRecording)
    #expect(controller.recordingLifecycleState == .recordingPressToTalk)
    #expect(!beforeStop.contains("capture.cancel"))
    #expect(!beforeStop.contains("media.release"))
    #expect(!beforeStop.contains("runtime.unload"))

    controller.pressToTalkStop()

    #expect(await waitForLifecycleEvent("runtime.unload", in: events))
    let afterStop = await events.snapshot()
    #expect(!afterStop.contains("capture.cancel"))
    assertEventOrder("capture.stop", before: "media.release", in: afterStop)
    assertEventOrder("media.release", before: "runtime.unload", in: afterStop)
    await controller.teardownAndWait()
}

@MainActor
@Test("Wake notification invalidates any retained runtime that survived sleep")
func wakeNotificationUnloadsRetainedRuntime() async {
    let events = LifecycleEventLog()
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: FakeMediaInterruptionService(events: events),
        coordinator: FakeDictationCoordinator(events: events)
    )

    NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.didWakeNotification,
        object: nil
    )

    #expect(await waitForLifecycleEvent("runtime.unload", in: events, attempts: 40))
    await controller.teardownAndWait()
}

@MainActor
@Test("System unload keeps a deferred settings rebuild inside the lifecycle transaction")
func systemUnloadSerializesDeferredRuntimeRebuild() async {
    let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoTests-\(UUID().uuidString)", isDirectory: true)
    let events = LifecycleEventLog()
    let processingGate = LifecycleGate()
    let shutdownGate = LifecycleGate()
    let unloadCompletions = AsyncCounter()
    let rebuilds = AsyncCounter()
    let owner = FakeDictationCoordinator(
        events: events,
        processingGate: processingGate,
        shutdownGate: shutdownGate,
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
    guard await waitForLifecycleEvent("owner.capture.ready", in: events) else {
        Issue.record("Start did not settle: \(await events.snapshot())")
        return
    }
    controller.pressToTalkStop()
    guard await waitForLifecycleEvent("owner.transcription.start", in: events) else {
        Issue.record("Completion did not begin: \(await events.snapshot())")
        return
    }

    controller.applySettingsDraft(preferences: controller.preferences)
    guard await waitForCondition({ controller.lifecycleDiagnostics.hasPendingRuntimeRebuild }) else {
        Issue.record("Settings rebuild was not deferred during transcription.")
        return
    }

    let unload = Task {
        await controller.unloadRuntimeForLifecycleTesting()
        await unloadCompletions.increment()
    }
    await processingGate.open()
    guard await waitForLifecycleEvent("owner.runtime.shutdown", in: events) else {
        Issue.record("Deferred rebuild did not reach owner shutdown: \(await events.snapshot())")
        return
    }

    for _ in 0..<20 {
        await Task.yield()
    }
    #expect(await unloadCompletions.value() == 0)

    await shutdownGate.open()
    await unload.value
    #expect(await unloadCompletions.value() == 1)
    #expect(await rebuilds.value() == 1)

    controller.pressToTalkStart()
    #expect(await waitForLifecycleEvent("replacement.capture.start", in: events))
    #expect((await events.snapshot()).filter { $0 == "owner.capture.start" }.count == 1)
}

@MainActor
@Test("Stop failure cancels capture before media ownership releases")
func stopFailureCancelsCaptureBeforeMediaRelease() async {
    let events = LifecycleEventLog()
    let cancelEntryGate = LifecycleGate()
    let coordinator = FakeDictationCoordinator(
        events: events,
        stopShouldFail: true,
        cancelEntryGate: cancelEntryGate
    )
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
    guard await waitForLifecycleEvent("capture.cancel.waiting", in: events) else {
        Issue.record("Stop fallback never reached its cancel gate: \(await events.snapshot())")
        controller.teardown()
        return
    }
    #expect(!(await waitForLifecycleEvent("media.release", in: events, attempts: 20)))
    await cancelEntryGate.open()
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
    let cancelEntryGate = LifecycleGate()
    let coordinator = FakeDictationCoordinator(
        events: events,
        cancelEntryGate: cancelEntryGate
    )
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
    guard await waitForLifecycleEvent("capture.cancel.waiting", in: events) else {
        Issue.record("Capture cancel never reached its gate: \(await events.snapshot())")
        controller.teardown()
        return
    }
    #expect(!(await waitForLifecycleEvent("media.release", in: events, attempts: 20)))
    await cancelEntryGate.open()
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
    let cancelEntryGate = LifecycleGate()
    let coordinator = FakeDictationCoordinator(
        events: events,
        cancelEntryGate: cancelEntryGate
    )
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
    guard await waitForLifecycleEvent("capture.cancel.waiting", in: events) else {
        Issue.record("Teardown cancel never reached its gate: \(await events.snapshot())")
        return
    }
    #expect(!(await waitForLifecycleEvent("media.release", in: events, attempts: 20)))
    await cancelEntryGate.open()
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
@Test("Newest settings rebuild owns the installed runtime")
func newestSettingsRebuildOwnsInstalledRuntime() async {
    let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoTests-\(UUID().uuidString)", isDirectory: true)
    let events = LifecycleEventLog()
    let ownerShutdownGate = LifecycleGate()
    let owner = FakeDictationCoordinator(
        events: events,
        shutdownGate: ownerShutdownGate,
        eventPrefix: "owner"
    )
    let latest = FakeDictationCoordinator(events: events, eventPrefix: "latest")
    let stale = FakeDictationCoordinator(events: events, eventPrefix: "stale")
    var rebuildCount = 0
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: FakeMediaInterruptionService(events: events),
        preferencesStore: AppPreferencesStore(
            storageURL: testDirectory.appendingPathComponent("preferences.json")
        ),
        coordinator: owner,
        runtimeRebuildOverride: {
            rebuildCount += 1
            return rebuildCount == 1 ? latest : stale
        }
    )
    defer {
        controller.teardown()
        try? FileManager.default.removeItem(at: testDirectory)
    }

    controller.applySettingsDraft(preferences: controller.preferences)
    guard await waitForLifecycleEvent("owner.runtime.shutdown", in: events) else {
        Issue.record("First rebuild did not begin owner shutdown: \(await events.snapshot())")
        return
    }

    controller.applySettingsDraft(preferences: controller.preferences)
    guard await waitForCondition({ rebuildCount == 1 }) else {
        Issue.record("Newest rebuild did not install while the older shutdown was pending")
        return
    }

    await ownerShutdownGate.open()
    try? await Task.sleep(nanoseconds: 20_000_000)
    controller.pressToTalkStart()
    #expect(await waitForAnyLifecycleEvent(
        ["latest.capture.start", "stale.capture.start"],
        in: events
    ))

    let snapshot = await events.snapshot()
    #expect(rebuildCount == 1)
    #expect(snapshot.contains("latest.capture.start"))
    #expect(!snapshot.contains("stale.capture.start"))
}

@MainActor
@Test("Teardown invalidates a rebuild waiting on old runtime shutdown")
func teardownInvalidatesPendingRuntimeRebuild() async {
    let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoTests-\(UUID().uuidString)", isDirectory: true)
    let events = LifecycleEventLog()
    let ownerShutdownGate = LifecycleGate()
    let owner = FakeDictationCoordinator(
        events: events,
        shutdownGate: ownerShutdownGate,
        eventPrefix: "owner"
    )
    let replacement = FakeDictationCoordinator(events: events, eventPrefix: "replacement")
    var rebuildCount = 0
    let controller = DictationController(
        hotkey: FakeHotkeyService(),
        mediaInterruption: FakeMediaInterruptionService(events: events),
        preferencesStore: AppPreferencesStore(
            storageURL: testDirectory.appendingPathComponent("preferences.json")
        ),
        coordinator: owner,
        runtimeRebuildOverride: {
            rebuildCount += 1
            return replacement
        }
    )
    defer { try? FileManager.default.removeItem(at: testDirectory) }

    controller.applySettingsDraft(preferences: controller.preferences)
    guard await waitForLifecycleEvent("owner.runtime.shutdown", in: events) else {
        Issue.record("Rebuild did not begin owner shutdown: \(await events.snapshot())")
        return
    }

    controller.teardown()
    let teardownCompletions = AsyncCounter()
    let teardownWaiter = Task {
        await controller.teardownAndWait()
        await teardownCompletions.increment()
    }
    for _ in 0..<20 {
        await Task.yield()
    }
    #expect(await teardownCompletions.value() == 0)

    await ownerShutdownGate.open()
    await teardownWaiter.value
    try? await Task.sleep(nanoseconds: 20_000_000)

    #expect(await teardownCompletions.value() == 1)
    #expect(rebuildCount == 0)
    #expect(!(await events.snapshot()).contains("replacement.runtime.shutdown"))
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

@MainActor
private final class OverlayDismissActionRecorder {
    private(set) var dismissCount = 0

    func dismiss() {
        dismissCount += 1
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
    private let stopEntryGate: LifecycleGate?
    private let cancelEntryGate: LifecycleGate?
    private let cancelGate: LifecycleGate?
    private let processingGates: [LifecycleGate]
    private var processingGateIndex = 0
    private let shutdownGate: LifecycleGate?
    private let eventPrefix: String?

    init(
        events: LifecycleEventLog,
        startShouldFail: Bool = false,
        startThrowsCancellation: Bool = false,
        stopShouldFail: Bool = false,
        startGate: LifecycleGate? = nil,
        stopEntryGate: LifecycleGate? = nil,
        cancelEntryGate: LifecycleGate? = nil,
        cancelGate: LifecycleGate? = nil,
        processingGate: LifecycleGate? = nil,
        processingGates: [LifecycleGate] = [],
        shutdownGate: LifecycleGate? = nil,
        eventPrefix: String? = nil
    ) {
        self.events = events
        self.startShouldFail = startShouldFail
        self.startThrowsCancellation = startThrowsCancellation
        self.stopShouldFail = stopShouldFail
        self.startGate = startGate
        self.stopEntryGate = stopEntryGate
        self.cancelEntryGate = cancelEntryGate
        self.cancelGate = cancelGate
        if processingGates.isEmpty, let processingGate {
            self.processingGates = [processingGate]
        } else {
            self.processingGates = processingGates
        }
        self.shutdownGate = shutdownGate
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
        if let stopEntryGate {
            await events.append(event("capture.stop.waiting"))
            await stopEntryGate.wait()
        }
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
        if processingGateIndex < processingGates.count {
            let gate = processingGates[processingGateIndex]
            processingGateIndex += 1
            await gate.wait()
        }
        return InsertResult(status: .noSpeech, method: .none, insertedText: "")
    }

    func cancel(sessionID: SessionID) async {
        if let cancelEntryGate {
            await events.append(event("capture.cancel.waiting"))
            await cancelEntryGate.wait()
        }
        await events.append(event("capture.cancel"))
        if let cancelGate {
            await cancelGate.wait()
        }
    }

    func setHandsFreeEnabled(_ enabled: Bool) async {
        await events.append(event("capture.ready"))
    }

    func unloadTranscriptionRuntime() async {
        await events.append(event("runtime.unload"))
    }

    func shutdown() async {
        await events.append(event("runtime.shutdown"))
        if let shutdownGate {
            await shutdownGate.wait()
        }
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

private func waitForLifecycleEventCount(
    _ event: String,
    count: Int,
    in log: LifecycleEventLog,
    attempts: Int = 400
) async -> Bool {
    for _ in 0..<attempts {
        if await log.snapshot().filter({ $0 == event }).count >= count {
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
