import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

@Suite(.serialized)
@MainActor
struct DictationControllerTranscriptionCancelTests {
    @Test("Cancel while transcribing inserts nothing, saves no History entry, and the next dictation works")
    func overlayCancelDuringTranscription() async throws {
        let harness = try TranscriptionCancelHarness()
        defer { harness.removeDirectory() }
        let controller = harness.controller

        controller.pressToTalkStart()
        try #require(await cancelTestEventually { await harness.capture.startedCount() == 1 })
        controller.pressToTalkStop()
        try #require(await cancelTestEventually { await harness.engine.startedCount() == 1 },
                     "Transcription never started: \(controller.status)")
        #expect(controller.recordingLifecycleState == .transcribing)
        #expect(harness.presenter.hostedEvidenceCancelIsAvailable())
        let firstRecording = try #require(await harness.capture.endedURLs().first)

        harness.presenter.hostedEvidencePressCancel()

        #expect(await cancelTestEventually { await harness.engine.cancelledCount() == 1 })
        #expect(await cancelTestEventually { @MainActor in controller.recordingLifecycleState == .idle })
        #expect(controller.status == "Transcription canceled.")
        #expect(controller.lastError.isEmpty)
        #expect(!harness.presenter.hostedEvidenceShownStates().contains { $0.isFailure })
        #expect(await cancelTestEventually { !FileManager.default.fileExists(atPath: firstRecording.path) })
        #expect(await harness.transport.texts().isEmpty)
        #expect(await harness.history.recent(limit: 10).isEmpty)

        // Dictating again right away works.
        controller.pressToTalkStart()
        try #require(await cancelTestEventually { await harness.capture.startedCount() == 2 })
        controller.pressToTalkStop()
        #expect(await cancelTestEventually { await harness.transport.texts() == ["Second dictation."] })
        #expect(await cancelTestEventually { @MainActor in controller.status == "Transcript inserted." })
        let entries = await harness.history.recent(limit: 10)
        #expect(entries.map(\.cleanText) == ["Second dictation."])

        controller.teardown()
        await harness.coordinator.shutdown()
    }
}

@MainActor
final class TranscriptionCancelHarness {
    let directory: URL
    let capture: TranscriptionCancelCapture
    let engine: FirstTranscriptionBlocksEngine
    let transport = TranscriptionCancelTransport()
    let history: HistoryStore
    let coordinator: SessionCoordinator
    let presenter: WaveformOverlayPresenter
    let controller: DictationController

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoTranscriptionCancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        capture = TranscriptionCancelCapture(directory: directory)
        engine = FirstTranscriptionBlocksEngine()
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
            editorTargetCapture: { _ in .failure(.unsupportedElement) }
        )
        presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.hostedEvidencePrepareOffscreen()
        controller = makeTestDictationController(
            hotkey: TranscriptionCancelHotkey(),
            overlay: presenter,
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

actor TranscriptionCancelCapture: AudioCaptureService {
    let directory: URL
    private var urls: [SessionID: URL] = [:]
    private var starts = 0
    private var ended: [URL] = []

    init(directory: URL) {
        self.directory = directory
    }

    func beginCapture(sessionID: SessionID) async throws {
        let url = directory.appendingPathComponent("\(sessionID.uuidString).wav")
        try cancelTestWAV(seconds: 1).write(to: url)
        urls[sessionID] = url
        starts += 1
    }

    func canonicalCaptureURL(sessionID: SessionID) async -> URL? {
        urls[sessionID]
    }

    func endCapture(sessionID: SessionID) async throws -> URL {
        guard let url = urls.removeValue(forKey: sessionID) else { throw CancellationError() }
        ended.append(url)
        return url
    }

    func cancelCapture(sessionID: SessionID) async {
        if let url = urls.removeValue(forKey: sessionID) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func startedCount() -> Int { starts }
    func endedURLs() -> [URL] { ended }
}

/// The first transcription never finishes on its own, like a stalled runtime.
actor FirstTranscriptionBlocksEngine: TranscriptionEngine {
    private var starts = 0
    private var cancels = 0
    private var blocked: CheckedContinuation<Void, Never>?

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        starts += 1
        guard starts == 1 else { return RawTranscript(text: "Second dictation.") }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                blocked = continuation
            }
        } onCancel: {
            Task { await self.release() }
        }
        cancels += 1
        throw CancellationError()
    }

    private func release() {
        blocked?.resume()
        blocked = nil
    }

    func startedCount() -> Int { starts }
    func cancelledCount() -> Int { cancels }
}

actor TranscriptionCancelTransport: InsertionTransport {
    nonisolated var method: InsertionMethod { .direct }
    private var values: [String] = []
    func insert(text: String, target: AppContext) async throws { values.append(text) }
    func texts() -> [String] { values }
}

@MainActor
final class TranscriptionCancelHotkey: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16? = 79
    func start() {}
    func stop() {}
}

func cancelTestWAV(seconds: Double) -> Data {
    let sampleCount = Int(seconds * 16_000)
    var pcm = Data(capacity: sampleCount * 2)
    for index in 0..<sampleCount {
        var sample = Int16(index.isMultiple(of: 2) ? 2_400 : -2_400).littleEndian
        withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
    }
    var data = Data("RIFF".utf8)
    func append<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    append(UInt32(36 + pcm.count))
    data.append(Data("WAVEfmt ".utf8))
    append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(UInt32(16_000)); append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
    data.append(Data("data".utf8))
    append(UInt32(pcm.count))
    data.append(pcm)
    return data
}

func cancelTestEventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<600 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}
