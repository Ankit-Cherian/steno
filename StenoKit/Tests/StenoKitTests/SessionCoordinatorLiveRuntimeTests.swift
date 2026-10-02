import Foundation
import Testing
import StenoKitTestSupport
@testable import StenoKit

// Drives the production SessionCoordinator and RetainedWhisperTranscriptionEngine.
// Only the helper-process runtime session and the capture service are faked.

private func liveRuntimeWAV(seconds: Double) throws -> URL {
    let sampleCount = Int(seconds * 16_000)
    var pcm = Data(capacity: sampleCount * 2)
    for index in 0..<sampleCount {
        let sample: Int16 = index.isMultiple(of: 2) ? 2_400 : -2_400
        var little = sample.littleEndian
        withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) }
    }
    var wav = Data()
    func ascii(_ value: String) { wav.append(contentsOf: value.utf8) }
    func u16(_ value: UInt16) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
    }
    func u32(_ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
    }
    ascii("RIFF"); u32(UInt32(36 + pcm.count)); ascii("WAVEfmt "); u32(16)
    u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
    ascii("data"); u32(UInt32(pcm.count)); wav.append(pcm)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-live-runtime-\(UUID().uuidString).wav")
    try wav.write(to: url)
    return url
}

/// Hands out a fresh WAV per session, as the production capture service does.
private actor LiveRuntimeCapture: AudioCaptureService {
    let seconds: Double
    private var urls: [SessionID: URL] = [:]

    init(seconds: Double) {
        self.seconds = seconds
    }

    func beginCapture(sessionID: SessionID) async throws {
        urls[sessionID] = try liveRuntimeWAV(seconds: seconds)
    }

    func canonicalCaptureURL(sessionID: SessionID) async -> URL? {
        urls[sessionID]
    }

    func endCapture(sessionID: SessionID) async throws -> URL {
        guard let url = urls[sessionID] else { throw CancellationError() }
        return url
    }

    func cancelCapture(sessionID: SessionID) async {
        _ = sessionID
    }
}

private func liveRuntimeJSON(_ text: String) -> Data {
    Data("{\"transcription\":[{\"offsets\":{\"from\":0,\"to\":900},\"text\":\" \(text)\",\"tokens\":[{\"text\":\" x\",\"p\":0.8}]}]}".utf8)
}

/// Mirrors the guards of ProcessWhisperStreamingRuntimeSession: a hypothesis
/// must name exactly the accepted watermark and cannot start while an append
/// is waiting for its acknowledgement.
private actor GuardedLiveRuntime: WhisperStreamingRuntimeSession {
    let appendDelay: Duration
    let decodeDelay: Duration
    private var acceptedWatermark: UInt64 = 0
    private var appending = false
    private var previewInFlight = false
    private(set) var rejectedHypotheses = 0
    private(set) var rejectedAppends: [String] = []
    private(set) var hypotheses = 0
    private(set) var cancelledStreams = 0
    private(set) var finishedStreams = 0
    private(set) var isShutDown = false

    init(appendDelay: Duration, decodeDelay: Duration) {
        self.appendDelay = appendDelay
        self.decodeDelay = decodeDelay
    }

    func transcribe(_ request: WhisperRuntimeRequest) async throws -> Data {
        liveRuntimeJSON("one shot")
    }

    func startStream(
        id: UUID,
        generation: UInt64,
        configuration: WhisperStreamConfiguration
    ) async throws -> LiveTranscriptionRuntimeIdentity {
        acceptedWatermark = 0
        appending = false
        previewInFlight = false
        return LiveTranscriptionRuntimeIdentity(
            protocolVersion: 2,
            runtimeIdentifier: "runtime",
            modelIdentifier: "model",
            vadIdentifier: "vad",
            currentASRContextCount: 1,
            peakASRContextCount: 1
        )
    }

    func append(_ chunk: WhisperStreamAudioChunk, streamID: UUID, generation: UInt64) async throws {
        guard !appending, chunk.sampleOffset == acceptedWatermark else {
            rejectedAppends.append("appending=\(appending) offset=\(chunk.sampleOffset) accepted=\(acceptedWatermark)")
            throw RetainedWhisperRuntimeError.staleResponse
        }
        appending = true
        try? await Task.sleep(for: appendDelay)
        acceptedWatermark = chunk.sampleOffset + UInt64(chunk.sampleCount)
        appending = false
    }

    func requestHypothesis(
        streamID: UUID,
        generation: UInt64,
        revision: UInt64,
        watermark: UInt64
    ) async throws -> WhisperStreamHypothesis {
        guard !appending, watermark == acceptedWatermark, !previewInFlight else {
            rejectedHypotheses += 1
            throw RetainedWhisperRuntimeError.staleResponse
        }
        previewInFlight = true
        hypotheses += 1
        try? await Task.sleep(for: decodeDelay)
        previewInFlight = false
        return WhisperStreamHypothesis(
            revision: revision,
            watermark: watermark,
            monotonicNanoseconds: revision * 1_000_000_000,
            speechEvidence: .speechDetected,
            text: "word \(revision)"
        )
    }

    func finishStream(id: UUID, generation: UInt64, request: WhisperStreamFinishRequest) async throws -> Data {
        finishedStreams += 1
        return liveRuntimeJSON("helper final")
    }

    func cancelStream(id: UUID, generation: UInt64) async {
        cancelledStreams += 1
    }

    func shutdown() async {
        isShutDown = true
    }
}

private final class GuardedLiveRuntimeFactory: WhisperRuntimeSessionFactory, @unchecked Sendable {
    let appendDelay: Duration
    let decodeDelay: Duration
    private let lock = NSLock()
    private var made: [GuardedLiveRuntime] = []

    init(appendDelay: Duration = .zero, decodeDelay: Duration = .milliseconds(5)) {
        self.appendDelay = appendDelay
        self.decodeDelay = decodeDelay
    }

    func makeSession(configuration: RetainedWhisperTranscriptionConfiguration) async throws -> any WhisperRuntimeSession {
        let session = GuardedLiveRuntime(appendDelay: appendDelay, decodeDelay: decodeDelay)
        lock.withLock { made.append(session) }
        return session
    }

    var sessions: [GuardedLiveRuntime] {
        lock.withLock { made }
    }
}

private struct FallbackMarkerEngine: TranscriptionEngine {
    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        RawTranscript(text: "fallback final")
    }
}

private actor LiveRuntimeEvents {
    private(set) var unavailable: [SessionID: [LiveTranscriptUnavailableReason]] = [:]
    private(set) var inserted: [String] = []
    private(set) var snapshots = 0

    func noteUnavailable(_ sessionID: SessionID, _ reason: LiveTranscriptUnavailableReason) {
        unavailable[sessionID, default: []].append(reason)
    }

    func noteInserted(_ text: String) {
        inserted.append(text)
    }

    func noteSnapshot() {
        snapshots += 1
    }
}

private func makeRetainedEngine(_ factory: GuardedLiveRuntimeFactory) -> RetainedWhisperTranscriptionEngine {
    RetainedWhisperTranscriptionEngine(
        configuration: RetainedWhisperTranscriptionConfiguration(
            helperExecutableURL: URL(fileURLWithPath: "/tmp/steno-helper"),
            modelPath: URL(fileURLWithPath: "/tmp/steno-model"),
            threadCount: 2,
            vadModelPath: URL(fileURLWithPath: "/tmp/steno-vad"),
            suppressNonSpeechTokens: true,
            suppressRegex: nil
        ),
        sessionFactory: factory,
        fallback: FallbackMarkerEngine()
    )
}

private func makeLiveCoordinator(
    engine: any TranscriptionEngine,
    capture: any AudioCaptureService,
    events: LiveRuntimeEvents
) -> SessionCoordinator {
    SessionCoordinator(
        captureService: capture,
        transcriptionEngine: engine,
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: InsertionService(transports: [
            ClosureInsertionTransport(method: .direct) { text, _ in await events.noteInserted(text) }
        ]),
        historyStore: HistoryStore(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("steno-live-runtime-history-\(UUID().uuidString).json"),
            clipboardService: MemoryClipboardService()
        ),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        liveSnapshotHandler: { _ in await events.noteSnapshot() },
        liveUnavailableHandler: { sessionID, reason in await events.noteUnavailable(sessionID, reason) }
    )
}

private enum CompletionOutcome: Equatable {
    case finished(String)
    case cancelled
    case failed(String)
    case hung
}

private actor OutcomeBox {
    var value: CompletionOutcome?
    func set(_ outcome: CompletionOutcome) { value = outcome }
}

private func outcome(
    of task: Task<InsertResult, Error>,
    within duration: Duration
) async -> CompletionOutcome {
    let box = OutcomeBox()
    Task {
        do {
            let result = try await task.value
            await box.set(.finished(result.insertedText))
        } catch is CancellationError {
            await box.set(.cancelled)
        } catch {
            await box.set(.failed("\(error)"))
        }
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: duration)
    while clock.now < deadline {
        if let value = await box.value { return value }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await box.value ?? .hung
}

/// Starts a live-preview dictation and waits until its pump has appended audio.
private func startLiveDictation(_ coordinator: SessionCoordinator) async throws -> SessionID {
    let sessionID = try await coordinator.startPressToTalk(
        appContext: .unknown,
        options: SessionStartOptions(livePreviewEnabled: true)
    )
    for _ in 0..<1_000 {
        if await coordinator.liveHypothesisSchedulingEvaluationWatermark(sessionID: sessionID) != nil {
            break
        }
        try await Task.sleep(for: .milliseconds(2))
    }
    return sessionID
}

/// One ordinary dictation, cancelled only the way DictationController does on failure.
private func dictate(
    _ coordinator: SessionCoordinator,
    within duration: Duration = .seconds(3)
) async throws -> (SessionID, CompletionOutcome) {
    let sessionID = try await startLiveDictation(coordinator)
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)
    let task = Task { try await coordinator.completePressToTalk(sessionID: sessionID) }
    let result = await outcome(of: task, within: duration)
    if result == .hung { task.cancel() }
    return (sessionID, result)
}

private final class CheckpointCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private let target: Int
    private var reached = 0

    init(cancelAt target: Int) {
        self.target = target
    }

    var didCancel: Bool {
        lock.withLock { reached >= target }
    }

    func observe(_ sessionID: SessionID) {
        let shouldCancel = lock.withLock {
            reached += 1
            return reached == target
        }
        if shouldCancel {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
}

// MARK: - A cancelled completion releases the live session

private actor RecordingLiveEngine: LiveTranscriptionEngine {
    private(set) var startCalls = 0
    private(set) var finishCalls = 0
    private(set) var cancelCalls = 0

    func startLiveTranscription(
        sessionID: SessionID,
        controllerGeneration: UUID,
        request: TranscriptionRequest
    ) async throws -> LiveTranscriptionSession {
        startCalls += 1
        return LiveTranscriptionSession(
            sessionID: sessionID,
            controllerGeneration: controllerGeneration,
            runtimeGeneration: 1,
            runtimeIdentity: LiveTranscriptionRuntimeIdentity(
                protocolVersion: 2,
                runtimeIdentifier: "runtime",
                modelIdentifier: "model",
                vadIdentifier: nil,
                currentASRContextCount: 1,
                peakASRContextCount: 1
            )
        )
    }

    func appendLiveAudio(_ frame: LivePCMFrame, session: LiveTranscriptionSession) async throws {}

    func requestLiveHypothesis(
        session: LiveTranscriptionSession,
        revision: UInt64,
        decodedAudioWatermark: UInt64
    ) async throws -> LiveTranscriptionEvent {
        LiveTranscriptionEvent(
            session: session,
            revision: revision,
            decodedAudioWatermark: decodedAudioWatermark,
            emittedAtMonotonicNanos: revision * 1_000_000_000,
            fullHypothesisText: "provisional",
            speechEvidence: .speechDetected
        )
    }

    func finishLiveTranscription(
        session: LiveTranscriptionSession,
        canonicalAudioURL: URL,
        streamSummary: LivePCMStreamSummary,
        request: TranscriptionRequest
    ) async throws -> RawTranscript {
        finishCalls += 1
        return RawTranscript(text: "hello world")
    }

    func cancelLiveTranscription(session: LiveTranscriptionSession) async {
        cancelCalls += 1
    }

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        RawTranscript(text: "hello world")
    }
}

@Test("A completion cancelled before it reaches the engine cancels the live session")
func cancelledCompletionCancelsLiveSessionOnEngine() async throws {
    let engine = RecordingLiveEngine()
    let events = LiveRuntimeEvents()
    let coordinator = makeLiveCoordinator(
        engine: engine,
        capture: LiveRuntimeCapture(seconds: 1),
        events: events
    )
    let sessionID = try await startLiveDictation(coordinator)
    #expect(await engine.startCalls == 1)
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)

    let completion = Task<InsertResult, Error> {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await coordinator.completePressToTalk(sessionID: sessionID)
    }
    #expect(await outcome(of: completion, within: .seconds(2)) == .cancelled)
    // DictationController's failure path.
    await coordinator.cancel(sessionID: sessionID)

    #expect(await engine.finishCalls == 0)
    #expect(await engine.cancelCalls == 1)
    #expect(await events.inserted.isEmpty)
}

@Test("A completion cancelled at any checkpoint leaves the retained engine ready for the next dictation")
func cancelledCompletionAtEveryCheckpointKeepsEngineUsable() async throws {
    var checkpoint = 1
    var cancelledCheckpoints = 0
    while checkpoint < 200 {
        let factory = GuardedLiveRuntimeFactory()
        let events = LiveRuntimeEvents()
        let coordinator = makeLiveCoordinator(
            engine: makeRetainedEngine(factory),
            capture: LiveRuntimeCapture(seconds: 1),
            events: events
        )

        let first = try await startLiveDictation(coordinator)
        try await coordinator.endPressToTalkCapture(sessionID: first)
        let canceller = CheckpointCanceller(cancelAt: checkpoint)
        await coordinator.setCompletionCheckpointObserver { canceller.observe($0) }
        let firstTask = Task { try await coordinator.completePressToTalk(sessionID: first) }
        let firstOutcome = await outcome(of: firstTask, within: .seconds(3))
        await coordinator.setCompletionCheckpointObserver(nil)
        await coordinator.cancel(sessionID: first)

        guard canceller.didCancel else {
            // The completion passed every checkpoint without being cancelled.
            #expect(firstOutcome == .finished("Helper final"))
            break
        }
        cancelledCheckpoints += 1
        #expect(firstOutcome == .cancelled, "checkpoint \(checkpoint)")
        #expect(await events.inserted.isEmpty, "checkpoint \(checkpoint)")

        let (second, secondOutcome) = try await dictate(coordinator)
        #expect(secondOutcome == .finished("Helper final"), "checkpoint \(checkpoint)")
        #expect(await events.unavailable[second] == nil, "checkpoint \(checkpoint)")
        checkpoint += 1
    }
    #expect(cancelledCheckpoints >= 4)
}

@Test("A completion cancelled during a tail append leaves the retained engine ready for the next dictation")
func cancelledCompletionDuringTailAppendKeepsEngineUsable() async throws {
    for cancelAfter in [10, 50, 90, 130, 170] {
        let factory = GuardedLiveRuntimeFactory(appendDelay: .milliseconds(40))
        let events = LiveRuntimeEvents()
        let coordinator = makeLiveCoordinator(
            engine: makeRetainedEngine(factory),
            capture: LiveRuntimeCapture(seconds: 3),
            events: events
        )
        let first = try await startLiveDictation(coordinator)
        try await coordinator.endPressToTalkCapture(sessionID: first)
        let firstTask = Task { try await coordinator.completePressToTalk(sessionID: first) }
        try await Task.sleep(for: .milliseconds(cancelAfter))
        firstTask.cancel()
        _ = await outcome(of: firstTask, within: .seconds(2))
        await coordinator.cancel(sessionID: first)

        let (second, secondOutcome) = try await dictate(coordinator)
        #expect(secondOutcome == .finished("Helper final"), "cancel after \(cancelAfter) ms")
        #expect(await events.unavailable[second] == nil, "cancel after \(cancelAfter) ms")
    }
}

private struct CaptureEndFailure: Error {}

/// Fails to close the first capture, then behaves normally.
private actor FirstStopFailingCapture: AudioCaptureService {
    private let base = LiveRuntimeCapture(seconds: 1)
    private var endCalls = 0

    func beginCapture(sessionID: SessionID) async throws {
        try await base.beginCapture(sessionID: sessionID)
    }

    func canonicalCaptureURL(sessionID: SessionID) async -> URL? {
        await base.canonicalCaptureURL(sessionID: sessionID)
    }

    func endCapture(sessionID: SessionID) async throws -> URL {
        endCalls += 1
        if endCalls == 1 { throw CaptureEndFailure() }
        return try await base.endCapture(sessionID: sessionID)
    }

    func cancelCapture(sessionID: SessionID) async {
        await base.cancelCapture(sessionID: sessionID)
    }
}

@Test("A capture that fails to stop releases its live session for the next dictation")
func failedCaptureStopReleasesLiveSession() async throws {
    let factory = GuardedLiveRuntimeFactory()
    let events = LiveRuntimeEvents()
    let coordinator = makeLiveCoordinator(
        engine: makeRetainedEngine(factory),
        capture: FirstStopFailingCapture(),
        events: events
    )
    let first = try await startLiveDictation(coordinator)
    await #expect(throws: (any Error).self) {
        try await coordinator.endPressToTalkCapture(sessionID: first)
    }
    await coordinator.cancel(sessionID: first)

    let (second, secondOutcome) = try await dictate(coordinator)
    #expect(secondOutcome == .finished("Helper final"))
    #expect(await events.unavailable[second] == nil)
}

// MARK: - Queued previews never collide with an append

@Test("A queued preview waits for the pump, so slow append acknowledgements never end live preview")
func queuedPreviewNeverCollidesWithAppend() async throws {
    for trial in 0..<3 {
        let factory = GuardedLiveRuntimeFactory(
            appendDelay: .milliseconds(8),
            decodeDelay: .milliseconds(120)
        )
        let events = LiveRuntimeEvents()
        let coordinator = makeLiveCoordinator(
            engine: makeRetainedEngine(factory),
            capture: LiveRuntimeCapture(seconds: 60),
            events: events
        )
        let sessionID = try await startLiveDictation(coordinator)
        try await Task.sleep(for: .seconds(2))
        try await coordinator.endPressToTalkCapture(sessionID: sessionID)
        let completion = Task { try await coordinator.completePressToTalk(sessionID: sessionID) }
        let final = await outcome(of: completion, within: .seconds(20))

        let runtime = try #require(factory.sessions.first)
        #expect(await events.unavailable[sessionID] == nil, "trial \(trial)")
        #expect(await runtime.rejectedHypotheses == 0, "trial \(trial)")
        // Enough to show previews kept coming; how many fit in two seconds
        // depends on how busy the machine is.
        #expect(await runtime.hypotheses >= 2, "trial \(trial)")
        #expect(await events.snapshots >= 2, "trial \(trial)")
        #expect(factory.sessions.count == 1, "trial \(trial)")
        let rejectedAppends = await runtime.rejectedAppends
        let finishedStreams = await runtime.finishedStreams
        #expect(rejectedAppends.isEmpty, "trial \(trial)")
        #expect(finishedStreams == 1, "trial \(trial)")
        #expect(final == .finished("Helper final"), "trial \(trial)")
    }
}

// MARK: - A stop between poll and append keeps every frame

private actor PollGate {
    private var armed = false
    private var reached = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func arm() { armed = true }
    func hasReached() -> Bool { reached }

    func pass() async {
        guard armed, !reached else { return }
        reached = true
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

@Test("A stop that lands between the pump's poll and its append keeps the live final")
func stopBetweenPollAndAppendKeepsLiveFinal() async throws {
    let factory = GuardedLiveRuntimeFactory()
    let events = LiveRuntimeEvents()
    let coordinator = makeLiveCoordinator(
        engine: makeRetainedEngine(factory),
        capture: LiveRuntimeCapture(seconds: 5),
        events: events
    )
    let gate = PollGate()
    await coordinator.setLivePumpPollObserver { await gate.pass() }
    let sessionID = try await startLiveDictation(coordinator)

    await gate.arm()
    for _ in 0..<500 where !(await gate.hasReached()) {
        try await Task.sleep(for: .milliseconds(2))
    }
    try #require(await gate.hasReached())
    // The pump holds a polled frame it has not appended yet.
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)
    let completion = Task { try await coordinator.completePressToTalk(sessionID: sessionID) }
    try await Task.sleep(for: .milliseconds(20))
    await gate.release()

    let final = await outcome(of: completion, within: .seconds(5))
    let runtime = try #require(factory.sessions.first)
    #expect(final == .finished("Helper final"))
    #expect(await runtime.rejectedAppends.isEmpty)
    #expect(await runtime.finishedStreams == 1)
}
