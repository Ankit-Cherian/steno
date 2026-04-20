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

@Test("SessionCoordinator returns noSpeech for hot-term prompt echo transcript")
func noSpeechGatePromptEchoTermsTranscript() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let capture = StubAudioCaptureService(queuedAudioURLs: [audioURL])
    let transcription = StaticTranscriptionEngine { _, _ in
        RawTranscript(text: "Terms: TURSO, RT.")
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

    let lexicon = PersonalLexiconService()
    await lexicon.upsert(term: "TURSO", preferred: "TURSO", scope: .global)
    await lexicon.upsert(term: "RT", preferred: "RT", scope: .global)

    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: transcription,
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: insertionService,
        historyStore: history,
        lexiconService: lexicon,
        styleProfileService: StyleProfileService()
    )

    let sessionID = try await coordinator.startPressToTalk(
        appContext: AppContext(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit")
    )
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.status == .noSpeech)
    #expect(result.method == .none)
    #expect(result.insertedText == "")
    #expect(await recorder.callCount() == 0)
    #expect(await history.recent(limit: 10).isEmpty)
}

@Test("SessionCoordinator returns noSpeech for app-and-terms prompt echo transcript")
func noSpeechGatePromptEchoAppAndTermsTranscript() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let capture = StubAudioCaptureService(queuedAudioURLs: [audioURL])
    let transcription = StaticTranscriptionEngine { _, _ in
        RawTranscript(text: "App: TextEdit. Terms: TURSO, RT.")
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

    let lexicon = PersonalLexiconService()
    await lexicon.upsert(term: "TURSO", preferred: "TURSO", scope: .global)
    await lexicon.upsert(term: "RT", preferred: "RT", scope: .global)

    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: transcription,
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: insertionService,
        historyStore: history,
        lexiconService: lexicon,
        styleProfileService: StyleProfileService()
    )

    let sessionID = try await coordinator.startPressToTalk(
        appContext: AppContext(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit")
    )
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.status == .noSpeech)
    #expect(result.method == .none)
    #expect(result.insertedText == "")
    #expect(await recorder.callCount() == 0)
    #expect(await history.recent(limit: 10).isEmpty)
}

@Test("SessionCoordinator strips repeated prompt labels around real content")
func promptContaminationStripsRepeatedMetadataLabels() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let capture = StubAudioCaptureService(queuedAudioURLs: [audioURL])
    let transcription = StaticTranscriptionEngine { _, _ in
        RawTranscript(text: "Terms: Can you imagine why Buckingham has been so violent? Terms: I suspect.")
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

    let lexicon = PersonalLexiconService()
    await lexicon.upsert(term: "TURSO", preferred: "TURSO", scope: .global)
    await lexicon.upsert(term: "RT", preferred: "RT", scope: .global)

    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: transcription,
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: insertionService,
        historyStore: history,
        lexiconService: lexicon,
        styleProfileService: StyleProfileService()
    )

    let sessionID = try await coordinator.startPressToTalk(
        appContext: AppContext(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit")
    )
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.status == .inserted)
    #expect(result.insertedText == "Can you imagine why Buckingham has been so violent? I suspect.")
    let entries = await history.recent(limit: 10)
    #expect(entries.count == 1)
    #expect(entries.first?.rawText == "Can you imagine why Buckingham has been so violent? I suspect.")
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
