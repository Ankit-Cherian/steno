import Foundation
import Testing
@testable import StenoKit

private enum FakeRuntimeFailure: Error {
    case crashed
}

private actor FakeRuntimeState {
    var loadCount = 0
    var shutdownCount = 0
    var fallbackCount = 0
    var activeRequests = 0
    var startedRequestCount = 0
    var maximumActiveRequests = 0
    var completedRequestIDs: [UUID] = []
    var failure: FakeRuntimeFailure?
    var ignoreCancellationDelayNanoseconds: UInt64 = 0
    var shouldBlockShutdown = false
    var shutdownStarted = false
    var shutdownContinuation: CheckedContinuation<Void, Never>?
    var loadStartedContinuations: [CheckedContinuation<Void, Never>] = []
    var requestStartedContinuations: [CheckedContinuation<Void, Never>] = []
    var shouldBlockRequest = false
    var requestBlockContinuations: [CheckedContinuation<Void, Never>] = []
    var requestCancellationCount = 0
    var requestCancellationContinuations: [CheckedContinuation<Void, Never>] = []

    func recordLoad() {
        loadCount += 1
        let continuations = loadStartedContinuations
        loadStartedContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func beginRequest() {
        activeRequests += 1
        startedRequestCount += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        let continuations = requestStartedContinuations
        requestStartedContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitUntilLoadStarts() async {
        guard loadCount == 0 else { return }
        await withCheckedContinuation { continuation in
            loadStartedContinuations.append(continuation)
        }
    }

    func waitUntilRequestStarts() async {
        guard startedRequestCount == 0 else { return }
        await withCheckedContinuation { continuation in
            requestStartedContinuations.append(continuation)
        }
    }

    func setBlockRequest(_ shouldBlock: Bool) {
        shouldBlockRequest = shouldBlock
    }

    func waitWhileRequestIsBlocked() async {
        guard shouldBlockRequest else { return }
        await withCheckedContinuation { continuation in
            requestBlockContinuations.append(continuation)
        }
    }

    func recordRequestCancellation() {
        requestCancellationCount += 1
        let continuations = requestCancellationContinuations
        requestCancellationContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitUntilRequestIsCancelled() async {
        guard requestCancellationCount == 0 else { return }
        await withCheckedContinuation { continuation in
            requestCancellationContinuations.append(continuation)
        }
    }

    func releaseBlockedRequest() {
        shouldBlockRequest = false
        let continuations = requestBlockContinuations
        requestBlockContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func finishRequest(id: UUID) {
        activeRequests -= 1
        completedRequestIDs.append(id)
    }

    func performShutdown() async {
        shutdownCount += 1
        shutdownStarted = true
        guard shouldBlockShutdown else { return }
        await withCheckedContinuation { continuation in
            shutdownContinuation = continuation
        }
    }

    func setBlockShutdown(_ shouldBlock: Bool) {
        shouldBlockShutdown = shouldBlock
    }

    func hasStartedShutdown() -> Bool {
        shutdownStarted
    }

    func releaseShutdown() {
        shouldBlockShutdown = false
        shutdownContinuation?.resume()
        shutdownContinuation = nil
    }

    func recordFallback() {
        fallbackCount += 1
    }

    func setFailure(_ failure: FakeRuntimeFailure?) {
        self.failure = failure
    }

    func setIgnoreCancellationDelay(_ nanoseconds: UInt64) {
        ignoreCancellationDelayNanoseconds = nanoseconds
    }

    func snapshot() -> (
        loads: Int,
        shutdowns: Int,
        fallbacks: Int,
        active: Int,
        maximumActive: Int,
        completed: [UUID],
        failure: FakeRuntimeFailure?,
        ignoreCancellationDelay: UInt64
    ) {
        (
            loadCount,
            shutdownCount,
            fallbackCount,
            activeRequests,
            maximumActiveRequests,
            completedRequestIDs,
            failure,
            ignoreCancellationDelayNanoseconds
        )
    }
}

private struct FakeWhisperRuntimeSessionFactory: WhisperRuntimeSessionFactory {
    let state: FakeRuntimeState
    var loadDelayNanoseconds: UInt64 = 0

    func makeSession(
        configuration: RetainedWhisperTranscriptionConfiguration
    ) async throws -> any WhisperRuntimeSession {
        _ = configuration
        await state.recordLoad()
        if loadDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: loadDelayNanoseconds)
        }
        return FakeWhisperRuntimeSession(state: state)
    }
}

private struct FakeWhisperRuntimeSession: WhisperRuntimeSession {
    let state: FakeRuntimeState

    func transcribe(_ request: WhisperRuntimeRequest) async throws -> Data {
        await state.beginRequest()
        await withTaskCancellationHandler {
            await state.waitWhileRequestIsBlocked()
        } onCancel: {
            Task { await state.recordRequestCancellation() }
        }
        let snapshot = await state.snapshot()
        do {
            if snapshot.ignoreCancellationDelay > 0 {
                do {
                    try await Task.sleep(nanoseconds: snapshot.ignoreCancellationDelay)
                } catch {
                    try? await Task.sleep(nanoseconds: snapshot.ignoreCancellationDelay)
                }
            }

            if let failure = snapshot.failure {
                throw failure
            }

            let text = request.audioURL.deletingPathExtension().lastPathComponent
            let output = richWhisperJSON(text: text)
            await state.finishRequest(id: request.id)
            return output
        } catch {
            await state.finishRequest(id: request.id)
            throw error
        }
    }

    func shutdown() async {
        await state.performShutdown()
    }
}

private struct CountingFallbackTranscriptionEngine: TranscriptionEngine {
    let state: FakeRuntimeState

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        _ = request
        await state.recordFallback()
        return RawTranscript(text: "fallback-\(audioURL.deletingPathExtension().lastPathComponent)")
    }
}

@Test("Retained runtime loads unchanged model once across sequential requests")
func retainedRuntimeLoadsOnceAcrossSequentialRequests() async throws {
    let state = FakeRuntimeState()
    let engine = makeRetainedEngine(state: state)

    let first = try await engine.transcribe(audioURL: URL(fileURLWithPath: "/tmp/first.wav"), request: .init())
    let second = try await engine.transcribe(audioURL: URL(fileURLWithPath: "/tmp/second.wav"), request: .init())

    #expect(first.text == "first")
    #expect(second.text == "second")
    let snapshot = await state.snapshot()
    #expect(snapshot.loads == 1)
    #expect(snapshot.shutdowns == 0)
    #expect(snapshot.fallbacks == 0)
}

@Test("Explicit benchmark preparation measures one load without running inference")
func retainedRuntimePreparationSeparatesLoadFromInference() async throws {
    let state = FakeRuntimeState()
    let engine = makeRetainedEngine(state: state)

    try await engine.prepareRetainedResources()
    var snapshot = await state.snapshot()
    #expect(snapshot.loads == 1)
    #expect(snapshot.completed.isEmpty)

    _ = try await engine.transcribe(
        audioURL: URL(fileURLWithPath: "/tmp/first-inference.wav"),
        request: .init()
    )
    snapshot = await state.snapshot()
    #expect(snapshot.loads == 1)
    #expect(snapshot.completed.count == 1)
}

@Test("Model and VAD identity changes reload once while request-only changes stay warm")
func retainedRuntimeInvalidatesOnlyLoadIdentity() async throws {
    let state = FakeRuntimeState()
    let engine = makeRetainedEngine(state: state)
    _ = try await engine.transcribe(audioURL: URL(fileURLWithPath: "/tmp/first.wav"), request: .init())

    var updated = retainedConfiguration()
    updated.threadCount = 8
    updated.suppressRegex = "noise"
    await engine.updateConfiguration(updated)
    _ = try await engine.transcribe(audioURL: URL(fileURLWithPath: "/tmp/request-only.wav"), request: .init())
    #expect((await state.snapshot()).loads == 1)

    updated.vadModelPath = URL(fileURLWithPath: "/tmp/vad-b.bin")
    await engine.updateConfiguration(updated)
    _ = try await engine.transcribe(audioURL: URL(fileURLWithPath: "/tmp/vad-change.wav"), request: .init())
    #expect((await state.snapshot()).loads == 2)
    #expect((await state.snapshot()).shutdowns == 1)

    updated.modelPath = URL(fileURLWithPath: "/tmp/model-b.bin")
    await engine.updateConfiguration(updated)
    _ = try await engine.transcribe(audioURL: URL(fileURLWithPath: "/tmp/model-change.wav"), request: .init())
    #expect((await state.snapshot()).loads == 3)
    #expect((await state.snapshot()).shutdowns == 2)
}

@Test("Runtime failure invokes the CLI fallback exactly once")
func retainedRuntimeFallsBackExactlyOnce() async throws {
    let state = FakeRuntimeState()
    await state.setFailure(.crashed)
    let engine = makeRetainedEngine(state: state)

    let result = try await engine.transcribe(
        audioURL: URL(fileURLWithPath: "/tmp/crash.wav"),
        request: .init()
    )

    #expect(result.text == "fallback-crash")
    let snapshot = await state.snapshot()
    #expect(snapshot.fallbacks == 1)
    #expect(snapshot.shutdowns == 1)
}

@Test("Cancellation during helper load returns promptly without fallback")
func retainedRuntimeCancellationDuringLoadDoesNotFallback() async throws {
    let state = FakeRuntimeState()
    let engine = RetainedWhisperTranscriptionEngine(
        configuration: retainedConfiguration(),
        sessionFactory: FakeWhisperRuntimeSessionFactory(
            state: state,
            loadDelayNanoseconds: 10_000_000_000
        ),
        fallback: CountingFallbackTranscriptionEngine(state: state)
    )

    let task = Task {
        try await engine.transcribe(audioURL: URL(fileURLWithPath: "/tmp/load.wav"), request: .init())
    }
    await state.waitUntilLoadStarts()
    let clock = ContinuousClock()
    let started = clock.now
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("Expected cancellation during load.")
    } catch is CancellationError {
        #expect(started.duration(to: clock.now) < .milliseconds(500))
    }
    #expect((await state.snapshot()).fallbacks == 0)
}

@Test("Cancellation during inference emits no late result and no fallback")
func retainedRuntimeCancellationDuringInferenceDropsLateResult() async throws {
    let state = FakeRuntimeState()
    await state.setIgnoreCancellationDelay(80_000_000)
    let engine = makeRetainedEngine(state: state)

    let task = Task {
        try await engine.transcribe(audioURL: URL(fileURLWithPath: "/tmp/late.wav"), request: .init())
    }
    try await Task.sleep(nanoseconds: 10_000_000)
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("A cancelled inference must not emit a late transcript.")
    } catch is CancellationError {
        // Expected.
    }
    #expect((await state.snapshot()).fallbacks == 0)
}

@Test("Cancellation invalidates the interrupted helper before a rapid restart")
func retainedRuntimeCancellationReloadsBeforeNextRequest() async throws {
    let state = FakeRuntimeState()
    await state.setIgnoreCancellationDelay(80_000_000)
    let engine = makeRetainedEngine(state: state)

    let cancelled = Task {
        try await engine.transcribe(
            audioURL: URL(fileURLWithPath: "/tmp/cancelled.wav"),
            request: .init()
        )
    }
    try await Task.sleep(nanoseconds: 10_000_000)
    cancelled.cancel()
    do {
        _ = try await cancelled.value
        Issue.record("A cancelled request must not return a transcript.")
    } catch is CancellationError {
        // Expected.
    }

    await state.setIgnoreCancellationDelay(0)
    let restarted = try await engine.transcribe(
        audioURL: URL(fileURLWithPath: "/tmp/restarted.wav"),
        request: .init()
    )

    #expect(restarted.text == "restarted")
    let snapshot = await state.snapshot()
    #expect(snapshot.loads == 2)
    #expect(snapshot.shutdowns == 1)
    #expect(snapshot.fallbacks == 0)
}

@Test("Overlapping requests are serialized and stale completion cannot satisfy a newer request")
func retainedRuntimeSerializesOverlappingRequests() async throws {
    let state = FakeRuntimeState()
    await state.setIgnoreCancellationDelay(30_000_000)
    let engine = makeRetainedEngine(state: state)

    async let first = engine.transcribe(audioURL: URL(fileURLWithPath: "/tmp/first.wav"), request: .init())
    async let second = engine.transcribe(audioURL: URL(fileURLWithPath: "/tmp/second.wav"), request: .init())
    let values = try await [first, second]

    #expect(Set(values.map(\.text)) == ["first", "second"])
    let snapshot = await state.snapshot()
    #expect(snapshot.maximumActive == 1)
    #expect(snapshot.active == 0)
}

@Test("Shutdown is idempotent, releases the runtime, and rejects new work")
func retainedRuntimeShutdownIsIdempotent() async throws {
    let state = FakeRuntimeState()
    let engine = makeRetainedEngine(state: state)
    _ = try await engine.transcribe(audioURL: URL(fileURLWithPath: "/tmp/warm.wav"), request: .init())

    await engine.shutdown()
    await engine.shutdown()

    #expect((await state.snapshot()).shutdowns == 1)
    do {
        _ = try await engine.transcribe(audioURL: URL(fileURLWithPath: "/tmp/after.wav"), request: .init())
        Issue.record("A shut down runtime must reject new work.")
    } catch RetainedWhisperRuntimeError.shutDown {
        // Expected.
    }
}

@Test("Concurrent shutdown callers await the same retained-runtime teardown")
func retainedRuntimeConcurrentShutdownCallersAwaitCompletion() async throws {
    let state = FakeRuntimeState()
    let engine = makeRetainedEngine(state: state)
    _ = try await engine.transcribe(audioURL: URL(fileURLWithPath: "/tmp/warm.wav"), request: .init())
    await state.setBlockShutdown(true)

    let first = Task { await engine.shutdown() }
    while !(await state.hasStartedShutdown()) {
        await Task.yield()
    }
    let secondCompleted = RetainedCompletionFlag()
    let second = Task {
        await engine.shutdown()
        await secondCompleted.markCompleted()
    }
    for _ in 0..<20 {
        await Task.yield()
    }
    #expect(await secondCompleted.value() == false)

    await state.releaseShutdown()
    await first.value
    await second.value
    #expect(await secondCompleted.value())
    #expect((await state.snapshot()).shutdowns == 1)
}

@Test("One hundred requests retain one context with no outstanding work")
func retainedRuntimeHundredRequestResourceHarness() async throws {
    let state = FakeRuntimeState()
    let engine = makeRetainedEngine(state: state)

    for index in 0..<100 {
        _ = try await engine.transcribe(
            audioURL: URL(fileURLWithPath: "/tmp/request-\(index).wav"),
            request: .init()
        )
    }

    let snapshot = await state.snapshot()
    #expect(snapshot.loads == 1)
    #expect(snapshot.active == 0)
    #expect(snapshot.completed.count == 100)
}

@Test("Reload drains old work before a newer request can start")
func retainedRuntimeReloadSerializesNewRequests() async throws {
    let state = FakeRuntimeState()
    await state.setBlockRequest(true)
    let engine = makeRetainedEngine(state: state)
    let oldRequest = Task {
        try await engine.transcribe(
            audioURL: URL(fileURLWithPath: "/tmp/old.wav"),
            request: .init()
        )
    }

    await state.waitUntilRequestStarts()
    await state.setBlockShutdown(true)
    var updated = retainedConfiguration()
    updated.modelPath = URL(fileURLWithPath: "/tmp/model-b.bin")
    let reload = Task { await engine.updateConfiguration(updated) }
    await state.waitUntilRequestIsCancelled()
    await state.releaseBlockedRequest()
    while !(await state.hasStartedShutdown()) {
        await Task.yield()
    }
    let newRequest = Task {
        try await engine.transcribe(
            audioURL: URL(fileURLWithPath: "/tmp/new.wav"),
            request: .init()
        )
    }

    for _ in 0..<20 {
        await Task.yield()
    }
    let blockedSnapshot = await state.snapshot()
    #expect(blockedSnapshot.loads == 1)
    #expect(blockedSnapshot.active == 0)

    do {
        _ = try await oldRequest.value
        Issue.record("Reload must cancel work owned by the old runtime generation.")
    } catch is CancellationError {
        // Expected.
    }
    await state.releaseShutdown()
    await reload.value
    #expect(try await newRequest.value.text == "new")

    let snapshot = await state.snapshot()
    #expect(snapshot.loads == 2)
    #expect(snapshot.shutdowns == 1)
    #expect(snapshot.fallbacks == 0)
    #expect(snapshot.maximumActive == 1)
}

@Test("Shared rich-output decoder preserves text, segments, confidence, duration, and artifacts")
func whisperTranscriptDecoderPreservesCLIContract() throws {
    let decoded = try #require(WhisperTranscriptDecoder.decodeRichJSON(
        richWhisperJSON(text: "[Music] hello world")
    ))

    #expect(decoded.text == "hello world")
    #expect(decoded.durationMS == 1_200)
    #expect(decoded.segments == [
        TranscriptSegment(startMS: 0, endMS: 1_200, text: "hello world", confidence: 0.75)
    ])
    #expect(abs((decoded.avgConfidence ?? 0) - 0.75) < 0.0001)
}

private func makeRetainedEngine(state: FakeRuntimeState) -> RetainedWhisperTranscriptionEngine {
    RetainedWhisperTranscriptionEngine(
        configuration: retainedConfiguration(),
        sessionFactory: FakeWhisperRuntimeSessionFactory(state: state),
        fallback: CountingFallbackTranscriptionEngine(state: state)
    )
}

private func retainedConfiguration() -> RetainedWhisperTranscriptionConfiguration {
    RetainedWhisperTranscriptionConfiguration(
        helperExecutableURL: URL(fileURLWithPath: "/tmp/steno-whisper-runtime"),
        modelPath: URL(fileURLWithPath: "/tmp/model-a.bin"),
        threadCount: 6,
        vadModelPath: URL(fileURLWithPath: "/tmp/vad-a.bin"),
        suppressNonSpeechTokens: true,
        suppressRegex: nil,
        beamSize: 5,
        bestOf: 5
    )
}

private actor RetainedCompletionFlag {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func value() -> Bool {
        completed
    }
}

private func richWhisperJSON(text: String) -> Data {
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return Data(
        """
        {
          "transcription": [
            {
              "offsets": { "from": 0, "to": 1200 },
              "text": " \(escaped)",
              "tokens": [
                { "text": " hello", "p": 0.9, "offsets": { "from": 0, "to": 500 } },
                { "text": " world", "p": 0.6, "offsets": { "from": 500, "to": 1200 } }
              ]
            }
          ]
        }
        """.utf8
    )
}
