import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

/// An Option tap or Option shortcut inside the Undo window is not a dictation. With a
/// confirming hotkey (like production `MacHotkeyMonitor`) the window ends only once the
/// press confirms; a discarded press leaves Undo offered and the parked audio intact.
@MainActor
@Suite("DictationControllerUndoWindow", .serialized)
struct DictationControllerUndoWindowTests {
    // MARK: - Control: the harness really holds a discard

    @Test("Control: after a confirmed Option dictation is discarded, Undo is offered and the audio is parked")
    func discardedLongRecordingIsHeldForUndo() async throws {
        let harness = try UndoWindowHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller

        let audio = try await harness.recordWithOptionThenDiscard()

        #expect(controller.canUndoDiscard)
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(controller.status == "Recording discarded. Undo restores it for a few seconds.")
        #expect(harness.presenter.hostedEvidenceRequestedStates().contains {
            if case .discarded = $0 { return true }
            return false
        }, "probe: the island offered the Discarded state")
        await harness.finish()
    }

    // MARK: - A press that is discarded before it confirms

    @Test(
        "An Option shortcut or short Option tap inside the Undo window leaves Undo and the parked audio alone",
        arguments: [false, true]
    )
    func optionShortcutInsideUndoWindowKeepsUndo(discardsBeforeCaptureStarts: Bool) async throws {
        let harness = try UndoWindowHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller

        let audio = try await harness.recordWithOptionThenDiscard()
        try #require(controller.canUndoDiscard)
        // Capture has closed and the discarded session has finished cleaning up, so the
        // next Option-down is not deferred by the cleanup gate.
        try #require(await undoWindowEventually { @MainActor in !controller.lifecycleDiagnostics.isCleanupInProgress })
        try #require(await undoWindowEventually { @MainActor in controller.recordingLifecycleState == .idle })
        try #require(FileManager.default.fileExists(atPath: audio.path))

        // Option goes down alone (the monitor emits start at once) ...
        harness.hotkey.onPressToTalkStart?()
        if !discardsBeforeCaptureStarts {
            // ... capture of the new press really starts (the start was not deferred) ...
            try #require(await undoWindowEventually { await harness.capture.startedCount() == 2 })
        }
        // ... and a second key arrives before 0.15 s: the filter emits discard, never confirm.
        harness.hotkey.onPressToTalkDiscarded?()

        try #require(await undoWindowEventually { @MainActor in controller.recordingLifecycleState == .idle })
        try #require(await undoWindowEventually { @MainActor in !controller.lifecycleDiagnostics.isCleanupInProgress })
        try await Task.sleep(for: .milliseconds(250))

        #expect(controller.canUndoDiscard, "an Option shortcut is not a dictation, so Undo is still offered")
        #expect(
            FileManager.default.fileExists(atPath: audio.path),
            "the discarded recording is still parked for Undo"
        )
        #expect(controller.status != "Recording discarded.", "the Undo status line was not rewritten")
        #expect(harness.presenter.hostedEvidenceIsVisible(), "the island still shows the discarded recording")
        #expect(harness.presenter.hostedEvidenceActionTitle() == "Undo", "the island still offers Undo")

        harness.presenter.hostedEvidencePressAction()
        #expect(await undoWindowEventually { @MainActor in controller.status == "Transcript inserted." })
        let insertedTexts = await harness.transport.texts()
        #expect(insertedTexts == ["Restored words"])
        #expect(await harness.engine.transcriptionCount() == 1)
        await harness.finish()
    }

    // MARK: - Control: a real, confirmed dictation still ends the window

    @Test("A confirmed Option dictation inside the Undo window still ends it and deletes the discarded audio")
    func confirmedOptionDictationEndsUndoWindow() async throws {
        let harness = try UndoWindowHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller

        let audio = try await harness.recordWithOptionThenDiscard()
        try #require(controller.canUndoDiscard)
        try #require(await undoWindowEventually { @MainActor in !controller.lifecycleDiagnostics.isCleanupInProgress })
        try #require(await undoWindowEventually { @MainActor in controller.recordingLifecycleState == .idle })

        harness.hotkey.onPressToTalkStart?()
        harness.hotkey.onPressToTalkConfirmed?()
        try #require(await undoWindowEventually { @MainActor in controller.isRecording })

        #expect(await undoWindowEventually { @MainActor in !controller.canUndoDiscard })
        #expect(await undoWindowEventually { !FileManager.default.fileExists(atPath: audio.path) })

        controller.cancelActiveRecording()
        await harness.finish()
    }
}

private func undoWindowEventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    await cancelTestEventually(condition)
}

// MARK: - Harness

/// Keeps every callback the controller sets and confirms presses, as `MacHotkeyMonitor` does.
private final class UndoWindowConfirmingHotkey: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var onPressToTalkConfirmed: (() -> Void)?
    var onPressToTalkDiscarded: (() -> Void)?
    var onPasteLastShortcut: (() -> Void)?
    var pasteLastShortcut: GlobalShortcut?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16?
    var confirmsPressToTalk: Bool { true }
    func start() {}
    func stop() {}
}

private actor UndoWindowEngine: TranscriptionEngine {
    private var count = 0
    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        count += 1
        return RawTranscript(text: "restored words")
    }
    func transcriptionCount() -> Int { count }
}

/// A fake that grants every Pause and records each call. It sends nothing to any real player.
@MainActor
private final class UndoWindowMediaService: MediaInterruptionService {
    private(set) var begun: [UUID] = []
    private(set) var ended: [UUID] = []

    func beginInterruption() async -> MediaInterruptionToken? {
        let token = MediaInterruptionToken()
        begun.append(token.id)
        return token
    }

    func endInterruption(token: MediaInterruptionToken) async {
        ended.append(token.id)
    }
}

/// The real controller and coordinator with a fake capture, engine, transport, clipboard and
/// media service, an offscreen overlay presenter and a temporary preferences file.
@MainActor
private final class UndoWindowHarness {
    let directory: URL
    let hotkey = UndoWindowConfirmingHotkey()
    let capture: TranscriptionCancelCapture
    let engine = UndoWindowEngine()
    let transport = TranscriptionCancelTransport()
    let clipboard = MemoryClipboardService()
    let media = UndoWindowMediaService()
    let history: HistoryStore
    let preferencesStore: AppPreferencesStore
    let coordinator: SessionCoordinator
    let presenter: WaveformOverlayPresenter
    let controller: DictationController
    var frontmost = AppContext(bundleIdentifier: "com.example.steno-test-editor", appName: "Test Editor")

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoUndoWindow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        capture = TranscriptionCancelCapture(directory: directory)
        history = HistoryStore(
            storageURL: directory.appendingPathComponent("history.json")
        )
        preferencesStore = AppPreferencesStore(storageURL: directory.appendingPathComponent("preferences.json"))
        let lookup: @Sendable (AppContext) -> Result<EditorTargetHandle, EditorTargetUnavailableReason> = { _ in
            .failure(.unsupportedElement)
        }
        coordinator = SessionCoordinator(
            captureService: capture,
            transcriptionEngine: engine,
            cleanupEngine: RuleBasedCleanupEngine(),
            insertionService: InsertionService(transports: [
                transport,
                ClipboardInsertionTransport(clipboard: clipboard),
            ]),
            historyStore: history,
            lexiconService: PersonalLexiconService(entries: []),
            styleProfileService: StyleProfileService(),
            editorTargetCapture: lookup
        )
        presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.hostedEvidencePrepareOffscreen()
        var provider: (@MainActor () -> AppContext)?
        controller = DictationController(
            hotkey: hotkey,
            clipboardService: clipboard,
            overlay: presenter,
            mediaInterruption: media,
            preferencesStore: preferencesStore,
            coordinator: coordinator,
            runtimeRebuildOverride: { nil },
            overlayDismissDelay: { try? await Task.sleep(for: .seconds(60)) },
            historyStore: history,
            usageAnalyticsStore: UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json")),
            legacyHistoryURL: directory.appendingPathComponent("legacy.json"),
            systemIntegrationsEnabled: false,
            appContextProvider: { provider?() ?? .unknown },
            targetDisplayPointProvider: { CGPoint(x: 400, y: 300) },
            workspaceNotificationCenter: nil
        )
        provider = { [unowned self] in self.frontmost }
        controller.undoDiscardMinimumRecording = 0
        controller.undoDiscardWindow = .seconds(30)
    }

    /// Holds Option past the confirmation delay, then discards with the island's x. Returns the
    /// parked audio file. Waits until the media pause was released and Undo is offered.
    func recordWithOptionThenDiscard() async throws -> URL {
        hotkey.onPressToTalkStart?()
        hotkey.onPressToTalkConfirmed?()
        try #require(await undoWindowEventually { await self.capture.startedCount() == 1 })
        try #require(await undoWindowEventually { @MainActor in self.controller.isRecording })
        try #require(await undoWindowEventually { @MainActor in self.media.begun.count == 1 })
        try #require(await undoWindowEventually { @MainActor in !self.controller.lifecycleDiagnostics.hasActiveStartTask })
        try await Task.sleep(for: .milliseconds(20))
        presenter.hostedEvidencePressCancel()
        try #require(await undoWindowEventually { @MainActor in !self.controller.isRecording })
        try #require(await undoWindowEventually { @MainActor in self.media.ended == self.media.begun })
        try #require(await undoWindowEventually { @MainActor in self.controller.canUndoDiscard })
        try #require(await undoWindowEventually { await self.capture.endedURLs().count == 1 })
        return try #require(await capture.endedURLs().first)
    }

    func finish() async {
        await controller.teardownAndWait()
        await coordinator.shutdown()
    }

    func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }
}
