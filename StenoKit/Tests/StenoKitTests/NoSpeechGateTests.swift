import Foundation
import Testing
import StenoKitTestSupport
@testable import StenoKit

@Test("SessionCoordinator returns noSpeech for empty transcript")
func noSpeechGateEmptyTranscript() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let capture = StubAudioCaptureService(queuedAudioURLs: [audioURL])
    let transcription = StaticTranscriptionEngine { _, _ in
        RawTranscript(text: "")
    }

    let recorder = InsertCallRecorder()
    let insertionService = InsertionService(
        transports: [
            ClosureInsertionTransport(method: .direct) { text, _ in
                await recorder.record(text)
            }
        ]
    )

    let historyURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("history-tests", isDirectory: true)
        .appendingPathComponent("history-\(UUID().uuidString).json")
    let history = HistoryStore(storageURL: historyURL, clipboardService: MemoryClipboardService())

    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: transcription,
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: insertionService,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.status == .noSpeech)
    #expect(result.method == .none)
    #expect(result.insertedText == "")
    #expect(await recorder.callCount() == 0)
    #expect(await history.recent(limit: 10).isEmpty)
}

@Test("SessionCoordinator returns noSpeech for whitespace-only transcript")
func noSpeechGateWhitespaceTranscript() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let capture = StubAudioCaptureService(queuedAudioURLs: [audioURL])
    let transcription = StaticTranscriptionEngine { _, _ in
        RawTranscript(text: "   \n  \t  ")
    }

    let insertionService = InsertionService(transports: [])

    let historyURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("history-tests", isDirectory: true)
        .appendingPathComponent("history-\(UUID().uuidString).json")
    let history = HistoryStore(storageURL: historyURL, clipboardService: MemoryClipboardService())

    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: transcription,
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: insertionService,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.status == .noSpeech)
    #expect(await history.recent(limit: 10).isEmpty)
}

@Test("SessionCoordinator proceeds normally for non-empty transcript")
func noSpeechGateNonEmptyTranscriptProceeds() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let capture = StubAudioCaptureService(queuedAudioURLs: [audioURL])
    let transcription = StaticTranscriptionEngine { _, _ in
        RawTranscript(text: "Hello world")
    }

    let recorder = InsertCallRecorder()
    let insertionService = InsertionService(
        transports: [
            ClosureInsertionTransport(method: .direct) { text, _ in
                await recorder.record(text)
            }
        ]
    )

    let historyURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("history-tests", isDirectory: true)
        .appendingPathComponent("history-\(UUID().uuidString).json")
    let history = HistoryStore(storageURL: historyURL, clipboardService: MemoryClipboardService())

    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: transcription,
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: insertionService,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.status == .inserted)
    #expect(await recorder.callCount() == 1)
    #expect(await history.recent(limit: 10).count == 1)
}

private actor InsertCallRecorder {
    private var calls: [String] = []

    func record(_ text: String) {
        calls.append(text)
    }

    func callCount() -> Int {
        calls.count
    }
}
