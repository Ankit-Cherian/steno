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

private actor BlockingBeginCaptureService: AudioCaptureService {
    private var beginContinuation: CheckedContinuation<Void, Never>?
    private var beginStarted = false
    private var cancelledCount = 0

    func beginCapture(sessionID: SessionID) async throws {
        _ = sessionID
        beginStarted = true
        await withCheckedContinuation { continuation in
            beginContinuation = continuation
        }
    }

    func endCapture(sessionID: SessionID) async throws -> URL {
        _ = sessionID
        throw CancellationError()
    }

    func cancelCapture(sessionID: SessionID) async {
        _ = sessionID
        cancelledCount += 1
    }

    func hasStartedBeginning() -> Bool {
        beginStarted
    }

    func releaseBegin() {
        beginContinuation?.resume()
        beginContinuation = nil
    }

    func cancellationCount() -> Int {
        cancelledCount
    }
}

private actor CancellationIgnoringTranscriptionGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool {
        started
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor LifecycleTrackingTranscriptionEngine: TranscriptionEngine {
    private var shutdownCount = 0
    private var unloadCount = 0

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        _ = audioURL
        _ = request
        return RawTranscript(text: "unused")
    }

    func shutdown() async {
        shutdownCount += 1
    }

    func unloadRetainedResources() async {
        unloadCount += 1
    }

    func counts() -> (shutdowns: Int, unloads: Int) {
        (shutdownCount, unloadCount)
    }
}

private actor BlockingShutdownTranscriptionEngine: TranscriptionEngine {
    private var shutdownCount = 0
    private var shutdownStarted = false
    private var shutdownContinuation: CheckedContinuation<Void, Never>?

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        _ = audioURL
        _ = request
        return RawTranscript(text: "unused")
    }

    func shutdown() async {
        shutdownCount += 1
        shutdownStarted = true
        await withCheckedContinuation { continuation in
            shutdownContinuation = continuation
        }
    }

    func hasStartedShutdown() -> Bool {
        shutdownStarted
    }

    func releaseShutdown() {
        shutdownContinuation?.resume()
        shutdownContinuation = nil
    }

    func count() -> Int {
        shutdownCount
    }
}

private actor CompletionFlag {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func value() -> Bool {
        completed
    }
}

private actor GatedInsertionState {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var sideEffects = 0

    func wait() async {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool {
        started
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func recordSideEffect() {
        sideEffects += 1
    }

    func sideEffectCount() -> Int {
        sideEffects
    }
}

private actor CommittedInsertionState {
    private var committed = false
    private var continuation: CheckedContinuation<Void, Never>?

    func commitAndWait() async {
        committed = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasCommitted() -> Bool {
        committed
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct GatedCancellationAwareInsertionTransport: InsertionTransport {
    let method: InsertionMethod = .direct
    let state: GatedInsertionState

    func insert(text: String, target: AppContext) async throws {
        _ = text
        _ = target
        await state.wait()
        try Task.checkCancellation()
        await state.recordSideEffect()
    }
}

private actor UsageEventCounter: UsageAnalyticsRecording {
    private var count = 0

    func record(event: UsageEvent) async throws {
        _ = event
        count += 1
    }

    func value() -> Int {
        count
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

@Test("Cancellation after capture close cannot insert, persist, or leak temporary audio")
func sessionCoordinatorCancellationAfterCaptureCloseHasNoSideEffects() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)
    let gate = CancellationIgnoringTranscriptionGate()
    let insertionRecorder = InsertRecorder()
    let historyURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("history-tests", isDirectory: true)
        .appendingPathComponent("history-\(UUID().uuidString).json")
    let history = HistoryStore(storageURL: historyURL, clipboardService: MemoryClipboardService())
    let coordinator = SessionCoordinator(
        captureService: StubAudioCaptureService(queuedAudioURLs: [audioURL]),
        transcriptionEngine: StaticTranscriptionEngine { _, _ in
            await gate.wait()
            return RawTranscript(text: "must never insert")
        },
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: InsertionService(
            transports: [
                ClosureInsertionTransport(method: .direct) { text, _ in
                    await insertionRecorder.record(text)
                }
            ]
        ),
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)
    let completion = Task {
        try await coordinator.completePressToTalk(sessionID: sessionID)
    }
    while !(await gate.hasStarted()) {
        await Task.yield()
    }

    completion.cancel()
    await coordinator.cancel(sessionID: sessionID)
    await gate.release()

    do {
        _ = try await completion.value
        Issue.record("A cancelled completion must not return an insertion result.")
    } catch is CancellationError {
        // Expected even when the transcription engine ignores cancellation.
    }
    #expect(await insertionRecorder.latest() == nil)
    #expect(await history.recent(limit: 1).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: audioURL.path))
}

@Test("SessionCoordinator unloads and shuts down retained transcription resources")
func sessionCoordinatorReleasesTranscriptionResources() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)
    let engine = LifecycleTrackingTranscriptionEngine()
    let coordinator = SessionCoordinator(
        captureService: StubAudioCaptureService(queuedAudioURLs: [audioURL]),
        transcriptionEngine: engine,
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
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)
    await coordinator.unloadTranscriptionRuntime()
    #expect((await engine.counts()).unloads == 1)
    #expect(!FileManager.default.fileExists(atPath: audioURL.path))

    await coordinator.shutdown()
    await coordinator.shutdown()
    #expect((await engine.counts()).shutdowns == 1)
}

@Test("Runtime unload wins a capture-start race without registering a ghost session")
func sessionCoordinatorRejectsCaptureThatFinishesDuringRuntimeUnload() async throws {
    let capture = BlockingBeginCaptureService()
    let engine = LifecycleTrackingTranscriptionEngine()
    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: engine,
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: InsertionService(transports: []),
        historyStore: HistoryStore(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("history-\(UUID().uuidString).json"),
            clipboardService: MemoryClipboardService()
        ),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )

    let starting = Task {
        try await coordinator.startPressToTalk(appContext: .unknown)
    }
    while !(await capture.hasStartedBeginning()) {
        await Task.yield()
    }

    await coordinator.unloadTranscriptionRuntime()
    await capture.releaseBegin()

    do {
        _ = try await starting.value
        Issue.record("A capture that crosses runtime unload must not become active.")
    } catch SessionCoordinatorError.runtimeUnavailable {
        // Expected: the lifecycle generation changed while capture start was suspended.
    }
    #expect(await capture.cancellationCount() == 1)
    #expect((await engine.counts()).unloads == 1)
}

@Test("Concurrent shutdown callers all await the same coordinator teardown")
func sessionCoordinatorConcurrentShutdownCallersAwaitCompletion() async throws {
    let engine = BlockingShutdownTranscriptionEngine()
    let coordinator = SessionCoordinator(
        captureService: StubAudioCaptureService(queuedAudioURLs: []),
        transcriptionEngine: engine,
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: InsertionService(transports: []),
        historyStore: HistoryStore(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("history-\(UUID().uuidString).json"),
            clipboardService: MemoryClipboardService()
        ),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )

    let first = Task { await coordinator.shutdown() }
    while !(await engine.hasStartedShutdown()) {
        await Task.yield()
    }
    let secondCompleted = CompletionFlag()
    let second = Task {
        await coordinator.shutdown()
        await secondCompleted.markCompleted()
    }
    for _ in 0..<20 {
        await Task.yield()
    }
    #expect(await secondCompleted.value() == false)

    await engine.releaseShutdown()
    await first.value
    await second.value
    #expect(await secondCompleted.value())
    #expect(await engine.count() == 1)
}

@Test("Cancellation during insertion cannot fall through, persist, or record usage")
func sessionCoordinatorCancellationDuringInsertionHasNoLaterSideEffects() async throws {
    let audioURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)
    let insertionState = GatedInsertionState()
    let fallbackRecorder = InsertRecorder()
    let usageCounter = UsageEventCounter()
    let history = HistoryStore(
        storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID().uuidString).json"),
        clipboardService: MemoryClipboardService()
    )
    let coordinator = SessionCoordinator(
        captureService: StubAudioCaptureService(queuedAudioURLs: [audioURL]),
        transcriptionEngine: StaticTranscriptionEngine { _, _ in
            RawTranscript(text: "must not insert")
        },
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: InsertionService(
            transports: [
                GatedCancellationAwareInsertionTransport(state: insertionState),
                ClosureInsertionTransport(method: .clipboardPaste) { text, _ in
                    await fallbackRecorder.record(text)
                },
            ]
        ),
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        usageRecorder: usageCounter
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)
    let completion = Task {
        try await coordinator.completePressToTalk(sessionID: sessionID)
    }
    while !(await insertionState.hasStarted()) {
        await Task.yield()
    }

    completion.cancel()
    await coordinator.cancel(sessionID: sessionID)
    await insertionState.release()

    do {
        _ = try await completion.value
        Issue.record("Cancellation during insertion must reject completion.")
    } catch is CancellationError {
        // Expected: no insertion fallback, history, or analytics may follow.
    }
    #expect(await insertionState.sideEffectCount() == 0)
    #expect(await fallbackRecorder.latest() == nil)
    #expect(await history.recent(limit: 1).isEmpty)
    #expect(await usageCounter.value() == 0)
    #expect(!FileManager.default.fileExists(atPath: audioURL.path))
}

@Test("Cancellation after insertion commit completes and persists exactly once")
func sessionCoordinatorCancellationAfterInsertionCommitCompletes() async throws {
    let audioURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)
    let insertionState = CommittedInsertionState()
    let history = HistoryStore(
        storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID().uuidString).json"),
        clipboardService: MemoryClipboardService()
    )
    let coordinator = SessionCoordinator(
        captureService: StubAudioCaptureService(queuedAudioURLs: [audioURL]),
        transcriptionEngine: StaticTranscriptionEngine { _, _ in
            RawTranscript(text: "complete text")
        },
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: InsertionService(
            transports: [
                ClosureInsertionTransport(method: .direct) { _, _ in
                    await insertionState.commitAndWait()
                }
            ]
        ),
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)
    let completion = Task {
        try await coordinator.completePressToTalk(sessionID: sessionID)
    }
    while !(await insertionState.hasCommitted()) {
        await Task.yield()
    }

    completion.cancel()
    await coordinator.cancel(sessionID: sessionID)
    await insertionState.release()

    let result = try await completion.value
    #expect(result.status == .inserted)
    #expect(result.insertedText == "Complete text")
    #expect((await history.recent(limit: 10)).count == 1)
    #expect(!FileManager.default.fileExists(atPath: audioURL.path))
}
