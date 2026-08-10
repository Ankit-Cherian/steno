import Foundation
import Testing
import StenoKitTestSupport
@testable import StenoKit

private actor InsertRecorder {
    private var inserts: [String] = []

    func record(_ text: String) {
        inserts.append(text)
    }

    func latest() -> String? {
        inserts.last
    }
}

private actor TranscriptionRequestRecorder {
    private var lastRequest: TranscriptionRequest?

    func record(_ request: TranscriptionRequest) {
        lastRequest = request
    }

    func latest() -> TranscriptionRequest? {
        lastRequest
    }
}

private actor BlockingEndCaptureService: AudioCaptureService {
    private let audioURL: URL
    private var endContinuation: CheckedContinuation<Void, Never>?
    private var endStarted = false

    init(audioURL: URL) {
        self.audioURL = audioURL
    }

    func beginCapture(sessionID: SessionID) async throws {
        _ = sessionID
    }

    func endCapture(sessionID: SessionID) async throws -> URL {
        _ = sessionID
        endStarted = true
        await withCheckedContinuation { continuation in
            endContinuation = continuation
        }
        return audioURL
    }

    func cancelCapture(sessionID: SessionID) async {
        _ = sessionID
    }

    func hasStartedEnding() -> Bool {
        endStarted
    }

    func releaseEnd() {
        endContinuation?.resume()
        endContinuation = nil
    }
}

@Test("SessionCoordinator marks localSuccess when primary cleanup succeeds")
func sessionCoordinatorLocalSuccessOutcome() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let capture = StubAudioCaptureService(queuedAudioURLs: [audioURL])
    let transcription = StaticTranscriptionEngine { _, _ in
        RawTranscript(text: "local success test")
    }

    let cleanupCounter = CleanupCounter()
    let cleanupEngine = CountingCleanupEngine(counter: cleanupCounter)

    let recorder = InsertRecorder()
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
        cleanupEngine: cleanupEngine,
        insertionService: insertionService,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.status == .inserted)
    #expect(result.cleanupOutcome?.source == .localSuccess)
    #expect(result.cleanupOutcome?.warning == nil)
    #expect(await cleanupCounter.value() == 1)

    let inserted = await recorder.latest() ?? ""
    #expect(inserted == "local success test cleaned")
}

@Test("SessionCoordinator falls back locally when primary cleanup fails")
func sessionCoordinatorLocalFallbackOnPrimaryFailure() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let capture = StubAudioCaptureService(queuedAudioURLs: [audioURL])
    let transcription = StaticTranscriptionEngine { _, _ in
        RawTranscript(text: "um stenoh can you clean this up")
    }

    let recorder = InsertRecorder()
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
    await lexicon.upsert(term: "stenoh", preferred: "Steno", scope: .global)

    let styles = StyleProfileService(
        globalProfile: StyleProfile(
            name: "Default",
            tone: .natural,
            structureMode: .paragraph,
            fillerPolicy: .balanced,
            commandPolicy: .transform
        )
    )

    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: transcription,
        cleanupEngine: FailingCleanupEngine(),
        insertionService: insertionService,
        historyStore: history,
        lexiconService: lexicon,
        styleProfileService: styles,
        fallbackCleanupEngine: RuleBasedCleanupEngine()
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes"))
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.status == .inserted)
    #expect(result.cleanupOutcome?.source == .localFallback)
    #expect(result.cleanupOutcome?.warning == "Primary cleanup unavailable, used local fallback.")

    let inserted = await recorder.latest() ?? ""
    #expect(inserted == "Um Steno can you clean this up")

    let recent = await history.recent(limit: 1)
    #expect(recent.count == 1)
    #expect(recent[0].cleanText == inserted)
    #expect(recent[0].audioURL == nil)
    #expect(recent[0].durationMS == 0)
}

@Test("SessionCoordinator keeps slash commands raw for IDE passthrough profile")
func sessionCoordinatorCommandPassthroughStaysLocalOnly() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let capture = StubAudioCaptureService(queuedAudioURLs: [audioURL])
    let transcription = StaticTranscriptionEngine { _, _ in
        RawTranscript(text: "/build target")
    }

    let recorder = InsertRecorder()
    let insertionService = InsertionService(
        transports: [
            ClosureInsertionTransport(method: .direct) { text, _ in
                await recorder.record(text)
            }
        ]
    )

    let style = StyleProfile(
        name: "IDE",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .minimal,
        commandPolicy: .passthrough
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
        styleProfileService: StyleProfileService(globalProfile: style)
    )

    let ideContext = AppContext(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode", isIDE: true)
    let sessionID = try await coordinator.startPressToTalk(appContext: ideContext)
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.status == .inserted)
    #expect(result.cleanupOutcome?.source == .localOnly)

    let inserted = await recorder.latest() ?? ""
    #expect(inserted == "/build target")
}

@Test("SessionCoordinator hands-free state uses explicit setter")
func sessionCoordinatorExplicitHandsFreeSetter() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let coordinator = SessionCoordinator(
        captureService: StubAudioCaptureService(queuedAudioURLs: [audioURL]),
        transcriptionEngine: StaticTranscriptionEngine { _, _ in RawTranscript(text: "test") },
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: InsertionService(transports: []),
        historyStore: HistoryStore(
            storageURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("history-tests", isDirectory: true)
                .appendingPathComponent("history-\(UUID().uuidString).json"),
            clipboardService: MemoryClipboardService()
        ),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )

    #expect(await coordinator.isHandsFreeEnabled == false)
    await coordinator.setHandsFreeEnabled(true)
    #expect(await coordinator.isHandsFreeEnabled == true)
    await coordinator.setHandsFreeEnabled(false)
    #expect(await coordinator.isHandsFreeEnabled == false)
}

@Test("SessionCoordinator forwards app context and hot terms to the transcription engine")
func sessionCoordinatorForwardsTranscriptionContext() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let capture = StubAudioCaptureService(queuedAudioURLs: [audioURL])
    let recorder = TranscriptionRequestRecorder()
    let transcription = StaticTranscriptionEngine { _, request in
        await recorder.record(request)
        return RawTranscript(text: "ping terso")
    }

    let historyURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("history-tests", isDirectory: true)
        .appendingPathComponent("history-\(UUID().uuidString).json")
    let history = HistoryStore(storageURL: historyURL, clipboardService: MemoryClipboardService())

    let lexicon = PersonalLexiconService()
    await lexicon.upsert(
        term: "TURSO",
        preferred: "TURSO",
        scope: .app(bundleID: "com.example.editor"),
        aliases: ["terso", "ter so"]
    )

    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: transcription,
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: InsertionService(transports: []),
        historyStore: history,
        lexiconService: lexicon,
        styleProfileService: StyleProfileService()
    )

    let appContext = AppContext(
        bundleIdentifier: "com.example.editor",
        appName: "EditorPro",
        isIDE: true
    )
    let sessionID = try await coordinator.startPressToTalk(appContext: appContext)
    _ = try await coordinator.stopPressToTalk(sessionID: sessionID)

    let request = await recorder.latest()
    #expect(request?.appContext == appContext)
    #expect(request?.hotTerms.contains("TURSO") == true)
}

@Test("SessionCoordinator cancel stops capture without creating history or insertion")
func sessionCoordinatorCancelSkipsHistoryAndInsertion() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let capture = StubAudioCaptureService(queuedAudioURLs: [audioURL])
    let recorder = InsertRecorder()
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
        transcriptionEngine: StaticTranscriptionEngine { _, _ in RawTranscript(text: "ignored") },
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: insertionService,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    await coordinator.cancel(sessionID: sessionID)

    let recent = await history.recent(limit: 10)
    #expect(recent.isEmpty)
    #expect(await recorder.latest() == nil)
}

@Test("SessionCoordinator can end capture before completing transcription")
func sessionCoordinatorSplitCaptureEndAndCompletion() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)
    let recorder = InsertRecorder()
    let coordinator = SessionCoordinator(
        captureService: StubAudioCaptureService(queuedAudioURLs: [audioURL]),
        transcriptionEngine: StaticTranscriptionEngine { _, _ in
            RawTranscript(text: "split lifecycle")
        },
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: InsertionService(
            transports: [
                ClosureInsertionTransport(method: .direct) { text, _ in
                    await recorder.record(text)
                }
            ]
        ),
        historyStore: HistoryStore(
            storageURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("history-tests", isDirectory: true)
                .appendingPathComponent("history-\(UUID().uuidString).json"),
            clipboardService: MemoryClipboardService()
        ),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)
    #expect(FileManager.default.fileExists(atPath: audioURL.path))

    let result = try await coordinator.completePressToTalk(sessionID: sessionID)

    #expect(result.status == .inserted)
    #expect(await recorder.latest() == result.insertedText)
    #expect(result.insertedText.lowercased().contains("split lifecycle"))
    #expect(!FileManager.default.fileExists(atPath: audioURL.path))
}

@Test("Cancel during capture end deletes audio and prevents completion")
func sessionCoordinatorCancelDuringCaptureEndPreventsCompletion() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)
    let capture = BlockingEndCaptureService(audioURL: audioURL)
    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: StaticTranscriptionEngine { _, _ in
            RawTranscript(text: "must not complete")
        },
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: InsertionService(transports: []),
        historyStore: HistoryStore(
            storageURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("history-tests", isDirectory: true)
                .appendingPathComponent("history-\(UUID().uuidString).json"),
            clipboardService: MemoryClipboardService()
        ),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    let ending = Task {
        try await coordinator.endPressToTalkCapture(sessionID: sessionID)
    }
    while !(await capture.hasStartedEnding()) {
        await Task.yield()
    }

    await coordinator.cancel(sessionID: sessionID)
    await capture.releaseEnd()

    do {
        try await ending.value
        Issue.record("Cancel during end should reject the captured session.")
    } catch is CancellationError {
        // Expected: cancellation wins the end/cancel race.
    }
    #expect(!FileManager.default.fileExists(atPath: audioURL.path))

    do {
        _ = try await coordinator.completePressToTalk(sessionID: sessionID)
        Issue.record("A canceled capture must not be available for completion.")
    } catch SessionCoordinatorError.sessionNotFound {
        // Expected: no captured session survives cancellation.
    }
}
