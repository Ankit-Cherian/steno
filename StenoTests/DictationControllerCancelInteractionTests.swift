import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

/// Cancel during transcription, combined with media pausing, usage recording,
/// and a recording the microphone cut short.
@Suite(.serialized)
@MainActor
struct DictationControllerCancelInteractionTests {
    @Test("Cancel while transcribing resumes paused media and records no History entry or usage event")
    func cancelResumesMediaAndRecordsNothing() async throws {
        let harness = try CancelInteractionHarness(interruptFirstRecording: false)
        defer { harness.removeDirectory() }
        let controller = harness.controller

        controller.pressToTalkStart()
        try #require(await cancelTestEventually { await harness.capture.startedCount() == 1 })
        try #require(await cancelTestEventually { @MainActor in harness.media.begun.count == 1 })
        controller.pressToTalkStop()
        try #require(await cancelTestEventually { await harness.engine.startedCount() == 1 },
                     "Transcription never started: \(controller.status)")

        harness.presenter.hostedEvidencePressCancel()

        #expect(await cancelTestEventually { @MainActor in controller.recordingLifecycleState == .idle })
        #expect(controller.status == "Transcription canceled.")
        #expect(harness.media.ended == harness.media.begun)
        #expect(await harness.transport.texts().isEmpty)
        #expect(await harness.history.recent(limit: 10).isEmpty)
        #expect(await harness.usage.recordedCount() == 0)

        // The next dictation records normally, so the recorder is wired.
        controller.pressToTalkStart()
        try #require(await cancelTestEventually { await harness.capture.startedCount() == 2 })
        controller.pressToTalkStop()
        #expect(await cancelTestEventually { @MainActor in controller.status == "Transcript inserted." })
        #expect(await cancelTestEventually { await harness.usage.recordedCount() == 1 })
        #expect(await harness.history.recent(limit: 10).map(\.cleanText) == ["Second dictation."])
        #expect(await cancelTestEventually { @MainActor in harness.media.ended == harness.media.begun })

        controller.teardown()
        await harness.coordinator.shutdown()
    }

    @Test("Cancel while transcribing a recording the microphone cut short leaves no microphone warning")
    func cancelLeavesNoStaleCaptureWarning() async throws {
        let harness = try CancelInteractionHarness(interruptFirstRecording: true)
        defer { harness.removeDirectory() }
        let controller = harness.controller

        controller.pressToTalkStart()
        try #require(await cancelTestEventually { await harness.capture.startedCount() == 1 })
        controller.pressToTalkStop()
        try #require(await cancelTestEventually { await harness.engine.startedCount() == 1 },
                     "Transcription never started: \(controller.status)")
        // The session being transcribed carries the microphone warning.
        #expect(await harness.capture.takenInterruptionCount() == 1)

        harness.presenter.hostedEvidencePressCancel()

        #expect(await cancelTestEventually { @MainActor in controller.recordingLifecycleState == .idle })
        #expect(controller.status == "Transcription canceled.")
        #expect(controller.lastError.isEmpty)
        #expect(!harness.presenter.hostedEvidenceShownStates().contains { $0.isFailure })

        // The next, uninterrupted dictation shows no leftover warning either.
        controller.pressToTalkStart()
        try #require(await cancelTestEventually { await harness.capture.startedCount() == 2 })
        controller.pressToTalkStop()
        #expect(await cancelTestEventually { @MainActor in controller.status == "Transcript inserted." })
        #expect(controller.lastError.isEmpty)
        #expect(!harness.presenter.hostedEvidenceShownStates().contains { $0.isFailure })

        controller.teardown()
        await harness.coordinator.shutdown()
    }
}

@MainActor
private final class CancelInteractionHarness {
    let directory: URL
    let capture: InterruptingCancelCapture
    let engine = FirstTranscriptionBlocksEngine()
    let transport = TranscriptionCancelTransport()
    let usage = CountingUsageRecorder()
    let media = RecordingMediaService()
    let history: HistoryStore
    let coordinator: SessionCoordinator
    let presenter: WaveformOverlayPresenter
    let controller: DictationController

    init(interruptFirstRecording: Bool) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoCancelInteraction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        capture = InterruptingCancelCapture(
            directory: directory,
            interruptFirstRecording: interruptFirstRecording
        )
        let clipboard = MemoryClipboardService()
        history = HistoryStore(
            storageURL: directory.appendingPathComponent("history.json"),
            clipboardService: clipboard
        )
        coordinator = SessionCoordinator(
            captureService: capture,
            transcriptionEngine: engine,
            cleanupEngine: RuleBasedCleanupEngine(),
            insertionService: InsertionService(transports: [transport]),
            historyStore: history,
            lexiconService: PersonalLexiconService(entries: []),
            styleProfileService: StyleProfileService(),
            usageRecorder: usage,
            editorTargetCapture: { _ in .failure(.unsupportedElement) }
        )
        presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.hostedEvidencePrepareOffscreen()
        controller = makeTestDictationController(
            hotkey: TranscriptionCancelHotkey(),
            overlay: presenter,
            mediaInterruption: media,
            preferencesStore: AppPreferencesStore(storageURL: directory.appendingPathComponent("preferences.json")),
            coordinator: coordinator,
            historyStore: history,
            usageAnalyticsStore: UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json")),
            legacyHistoryURL: directory.appendingPathComponent("legacy.json")
        )
    }

    func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Writes a short recording per session and, when asked, reports that the
/// first one was cut short by the microphone.
private actor InterruptingCancelCapture: AudioCaptureService {
    let directory: URL
    private let interruptFirstRecording: Bool
    private var urls: [SessionID: URL] = [:]
    private var interruptions: [SessionID: CaptureInterruption] = [:]
    private var starts = 0
    private var taken = 0

    init(directory: URL, interruptFirstRecording: Bool) {
        self.directory = directory
        self.interruptFirstRecording = interruptFirstRecording
    }

    func beginCapture(sessionID: SessionID) async throws {
        let url = directory.appendingPathComponent("\(sessionID.uuidString).wav")
        try cancelTestWAV(seconds: 1).write(to: url)
        urls[sessionID] = url
        starts += 1
        if starts == 1, interruptFirstRecording {
            interruptions[sessionID] = CaptureInterruption(reason: .recorderStopped, deviceName: "Fictional USB Mic")
        }
    }

    func canonicalCaptureURL(sessionID: SessionID) async -> URL? {
        urls[sessionID]
    }

    func endCapture(sessionID: SessionID) async throws -> URL {
        guard let url = urls.removeValue(forKey: sessionID) else { throw CancellationError() }
        return url
    }

    func cancelCapture(sessionID: SessionID) async {
        interruptions.removeValue(forKey: sessionID)
        if let url = urls.removeValue(forKey: sessionID) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func takeCaptureInterruption(sessionID: SessionID) async -> CaptureInterruption? {
        let interruption = interruptions.removeValue(forKey: sessionID)
        if interruption != nil { taken += 1 }
        return interruption
    }

    func startedCount() -> Int { starts }
    func takenInterruptionCount() -> Int { taken }
}

private actor CountingUsageRecorder: UsageAnalyticsRecording {
    private var count = 0
    func record(event: UsageEvent) async throws { count += 1 }
    func recordedCount() -> Int { count }
}

/// Grants every Pause and records which tokens the controller released.
@MainActor
private final class RecordingMediaService: MediaInterruptionService {
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
