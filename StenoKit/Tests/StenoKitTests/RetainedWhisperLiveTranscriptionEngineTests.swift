import Foundation
import Testing
@testable import StenoKit

private enum FakeLiveRuntimeFailure: Error, Equatable {
    case append
    case hypothesis
    case finish
    case fallback
}

private actor FakeLiveRuntimeState {
    var loadCount = 0
    var shutdownCount = 0
    var fallbackCount = 0
    var oneShotRequests: [WhisperRuntimeRequest] = []
    var starts: [(UUID, UInt64, WhisperStreamConfiguration)] = []
    var chunks: [WhisperStreamAudioChunk] = []
    var hypothesisRequests: [(UUID, UInt64, UInt64, UInt64)] = []
    var finishRequests: [(UUID, UInt64, WhisperStreamFinishRequest)] = []
    var finishAttemptCount = 0
    var cancellations: [(UUID, UInt64)] = []
    var failure: FakeLiveRuntimeFailure?
    var shouldFailFallback = false
    var shouldBlockAppend = false
    var appendStarted = false
    var appendContinuation: CheckedContinuation<Void, Error>?
    var shouldBlockHypothesis = false
    var hypothesisStarted = false
    var hypothesisContinuation: CheckedContinuation<Void, Error>?
    var shouldBlockFinish = false
    var finishStarted = false
    var finishContinuation: CheckedContinuation<Void, Error>?

    func recordLoad() {
        loadCount += 1
    }

    func recordShutdown() {
        shutdownCount += 1
    }

    func recordFallback() throws {
        fallbackCount += 1
        if shouldFailFallback {
            throw FakeLiveRuntimeFailure.fallback
        }
    }

    func recordOneShot(_ request: WhisperRuntimeRequest) {
        oneShotRequests.append(request)
    }

    func recordStart(
        id: UUID,
        generation: UInt64,
        configuration: WhisperStreamConfiguration
    ) {
        starts.append((id, generation, configuration))
    }

    func recordAppend(_ chunk: WhisperStreamAudioChunk) async throws {
        if failure == .append {
            throw FakeLiveRuntimeFailure.append
        }
        chunks.append(chunk)
        guard shouldBlockAppend else { return }
        appendStarted = true
        try await withCheckedThrowingContinuation { continuation in
            appendContinuation = continuation
        }
    }

    func recordHypothesis(
        id: UUID,
        generation: UInt64,
        revision: UInt64,
        watermark: UInt64
    ) async throws {
        if failure == .hypothesis {
            throw FakeLiveRuntimeFailure.hypothesis
        }
        hypothesisRequests.append((id, generation, revision, watermark))
        guard shouldBlockHypothesis else { return }
        hypothesisStarted = true
        try await withCheckedThrowingContinuation { continuation in
            hypothesisContinuation = continuation
        }
    }

    func recordFinish(
        id: UUID,
        generation: UInt64,
        request: WhisperStreamFinishRequest
    ) async throws {
        finishAttemptCount += 1
        appendContinuation?.resume(throwing: RetainedWhisperRuntimeError.staleResponse)
        appendContinuation = nil
        shouldBlockAppend = false
        hypothesisContinuation?.resume(throwing: RetainedWhisperRuntimeError.staleResponse)
        hypothesisContinuation = nil
        shouldBlockHypothesis = false
        if shouldBlockFinish {
            finishStarted = true
            try await withCheckedThrowingContinuation { continuation in
                finishContinuation = continuation
            }
        }
        if failure == .finish {
            throw FakeLiveRuntimeFailure.finish
        }
        finishRequests.append((id, generation, request))
    }

    func recordCancellation(id: UUID, generation: UInt64) {
        cancellations.append((id, generation))
        finishContinuation?.resume(throwing: CancellationError())
        finishContinuation = nil
        shouldBlockFinish = false
    }

    func setFailure(_ failure: FakeLiveRuntimeFailure?) {
        self.failure = failure
    }

    func setFallbackFailure(_ shouldFail: Bool) {
        shouldFailFallback = shouldFail
    }

    func blockNextHypothesis() {
        shouldBlockHypothesis = true
    }

    func blockNextAppend() {
        shouldBlockAppend = true
    }

    func blockNextFinish() {
        shouldBlockFinish = true
    }

    func hasStartedAppend() -> Bool {
        appendStarted
    }

    func hasStartedHypothesis() -> Bool {
        hypothesisStarted
    }

    func hasStartedFinish() -> Bool {
        finishStarted
    }
}

private struct FakeLiveRuntimeFactory: WhisperRuntimeSessionFactory {
    let state: FakeLiveRuntimeState

    func makeSession(
        configuration: RetainedWhisperTranscriptionConfiguration
    ) async throws -> any WhisperRuntimeSession {
        _ = configuration
        await state.recordLoad()
        return FakeLiveRuntimeSession(state: state)
    }
}

private actor FakeLiveRuntimeSession: WhisperStreamingRuntimeSession {
    let state: FakeLiveRuntimeState

    init(state: FakeLiveRuntimeState) {
        self.state = state
    }

    func transcribe(_ request: WhisperRuntimeRequest) async throws -> Data {
        await state.recordOneShot(request)
        return liveRichJSON(text: request.audioURL.deletingPathExtension().lastPathComponent)
    }

    func startStream(
        id: UUID,
        generation: UInt64,
        configuration: WhisperStreamConfiguration
    ) async throws -> LiveTranscriptionRuntimeIdentity {
        await state.recordStart(id: id, generation: generation, configuration: configuration)
        return testLiveRuntimeIdentity
    }

    func append(
        _ chunk: WhisperStreamAudioChunk,
        streamID: UUID,
        generation: UInt64
    ) async throws {
        _ = streamID
        _ = generation
        try await state.recordAppend(chunk)
    }

    func requestHypothesis(
        streamID: UUID,
        generation: UInt64,
        revision: UInt64,
        watermark: UInt64
    ) async throws -> WhisperStreamHypothesis {
        try await state.recordHypothesis(
            id: streamID,
            generation: generation,
            revision: revision,
            watermark: watermark
        )
        return WhisperStreamHypothesis(
            revision: revision,
            watermark: watermark,
            monotonicNanoseconds: 123_456,
            speechEvidence: .speechDetected,
            text: "live hypothesis"
        )
    }

    func finishStream(
        id: UUID,
        generation: UInt64,
        request: WhisperStreamFinishRequest
    ) async throws -> Data {
        try await state.recordFinish(id: id, generation: generation, request: request)
        return liveRichJSON(text: "authoritative live final")
    }

    func cancelStream(id: UUID, generation: UInt64) async {
        await state.recordCancellation(id: id, generation: generation)
    }

    func shutdown() async {
        await state.recordShutdown()
    }
}

private let testLiveRuntimeIdentity = LiveTranscriptionRuntimeIdentity(
    protocolVersion: 2,
    runtimeIdentifier: "test-runtime",
    modelIdentifier: "test-model",
    vadIdentifier: "test-vad"
)

private struct FakeLiveFallbackEngine: TranscriptionEngine {
    let state: FakeLiveRuntimeState

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        _ = request
        try await state.recordFallback()
        return RawTranscript(text: "fallback-\(audioURL.deletingPathExtension().lastPathComponent)")
    }
}

@Test("Live final and later ordinary final share one retained model")
func retainedLiveAndOrdinaryFinalShareOneModel() async throws {
    let state = FakeLiveRuntimeState()
    let engine = makeLiveEngine(state: state)
    let captureID = UUID()
    let controllerGeneration = UUID()
    let request = TranscriptionRequest(languageHints: ["en-US"], hotTerms: ["Steno"])

    let live = try await engine.startLiveTranscription(
        sessionID: captureID,
        controllerGeneration: controllerGeneration,
        request: request
    )
    let frame = LivePCMFrame(
        sequenceNumber: 0,
        sampleOffset: 0,
        pcmS16LE: Data([1, 0, 2, 0, 3, 0])
    )
    try await engine.appendLiveAudio(frame, session: live)
    let event = try await engine.requestLiveHypothesis(
        session: live,
        revision: 1,
        decodedAudioWatermark: 3
    )
    let final = try await engine.finishLiveTranscription(
        session: live,
        canonicalAudioURL: URL(fileURLWithPath: "/tmp/live.wav"),
        streamSummary: liveSummary(for: frame),
        request: request
    )
    let ordinary = try await engine.transcribe(
        audioURL: URL(fileURLWithPath: "/tmp/ordinary.wav"),
        request: request
    )

    #expect(live.sessionID == captureID)
    #expect(live.controllerGeneration == controllerGeneration)
    #expect(live.runtimeIdentity == testLiveRuntimeIdentity)
    #expect(event.session == live)
    #expect(event.runtimeIdentity == testLiveRuntimeIdentity)
    #expect(event.revision == 1)
    #expect(event.decodedAudioWatermark == 3)
    #expect(event.emittedAtMonotonicNanos == 123_456)
    #expect(event.fullHypothesisText == "live hypothesis")
    #expect(event.speechEvidence == .speechDetected)
    #expect(final.text == "authoritative live final")
    #expect(final.durationMS == 900)
    #expect(ordinary.text == "ordinary")
    #expect(await state.loadCount == 1)
    #expect(await state.shutdownCount == 0)
    #expect(await state.fallbackCount == 0)
    #expect(await state.starts.count == 1)
    #expect(await state.finishRequests.count == 1)
    #expect(await state.oneShotRequests.count == 1)
}

@Test("Live append maps exact ordered PCM accounting and bounded prompt configuration")
func retainedLiveAppendMapsExactPCMAndPrompt() async throws {
    let state = FakeLiveRuntimeState()
    let engine = makeLiveEngine(state: state)
    let request = TranscriptionRequest(
        languageHints: ["en-US"],
        hotTerms: ["Aqua", "Wispr"]
    )
    let live = try await engine.startLiveTranscription(
        sessionID: UUID(),
        controllerGeneration: UUID(),
        request: request
    )
    let bytes = Data([0x10, 0x00, 0x20, 0x00])
    try await engine.appendLiveAudio(
        LivePCMFrame(sequenceNumber: 7, sampleOffset: 41, pcmS16LE: bytes),
        session: live
    )

    let starts = await state.starts
    let chunks = await state.chunks
    #expect(starts.count == 1)
    #expect(starts[0].2.language == "en")
    #expect(starts[0].2.prompt == "Language: en. Terms: Aqua, Wispr.")
    #expect(chunks == [
        try WhisperStreamAudioChunk(
            sequence: 7,
            sampleOffset: 41,
            sampleCount: 2,
            samplesS16LE: bytes
        )
    ])
}

@Test("Live preview fails closed without local VAD while retained final remains available")
func retainedLiveRequiresVADButPreservesFinalOnlyRuntime() async throws {
    let state = FakeLiveRuntimeState()
    let engine = RetainedWhisperTranscriptionEngine(
        configuration: liveConfiguration(vadModelPath: nil),
        sessionFactory: FakeLiveRuntimeFactory(state: state),
        fallback: FakeLiveFallbackEngine(state: state)
    )

    await #expect(throws: RetainedWhisperRuntimeError.unsupportedConfiguration) {
        _ = try await engine.startLiveTranscription(
            sessionID: UUID(),
            controllerGeneration: UUID(),
            request: .init()
        )
    }

    let final = try await engine.transcribe(
        audioURL: URL(fileURLWithPath: "/tmp/final-only.wav"),
        request: .init()
    )
    #expect(final.text == "final-only")
    #expect(await state.loadCount == 1)
    #expect(await state.oneShotRequests.count == 1)
    #expect(await state.fallbackCount == 0)
}

@Test("Live session identity rejects stale and overlapping work")
func retainedLiveRejectsStaleIdentity() async throws {
    let state = FakeLiveRuntimeState()
    let engine = makeLiveEngine(state: state)
    let live = try await engine.startLiveTranscription(
        sessionID: UUID(),
        controllerGeneration: UUID(),
        request: .init()
    )
    let stale = LiveTranscriptionSession(
        sessionID: live.sessionID,
        controllerGeneration: UUID(),
        runtimeGeneration: live.runtimeGeneration,
        runtimeIdentity: live.runtimeIdentity
    )
    let wrongRuntimeIdentity = LiveTranscriptionSession(
        sessionID: live.sessionID,
        controllerGeneration: live.controllerGeneration,
        runtimeGeneration: live.runtimeGeneration,
        runtimeIdentity: LiveTranscriptionRuntimeIdentity(
            protocolVersion: 2,
            runtimeIdentifier: "other-runtime",
            modelIdentifier: live.runtimeIdentity.modelIdentifier,
            vadIdentifier: live.runtimeIdentity.vadIdentifier
        )
    )

    await #expect(throws: RetainedWhisperRuntimeError.unsupportedConfiguration) {
        _ = try await engine.startLiveTranscription(
            sessionID: UUID(),
            controllerGeneration: UUID(),
            request: .init()
        )
    }
    await #expect(throws: RetainedWhisperRuntimeError.staleResponse) {
        try await engine.appendLiveAudio(
            LivePCMFrame(sequenceNumber: 0, sampleOffset: 0, pcmS16LE: Data([0, 0])),
            session: stale
        )
    }
    await #expect(throws: RetainedWhisperRuntimeError.staleResponse) {
        try await engine.appendLiveAudio(
            LivePCMFrame(sequenceNumber: 0, sampleOffset: 0, pcmS16LE: Data([0, 0])),
            session: wrongRuntimeIdentity
        )
    }
    await #expect(throws: RetainedWhisperRuntimeError.staleResponse) {
        _ = try await engine.requestLiveHypothesis(
            session: stale,
            revision: 1,
            decodedAudioWatermark: 0
        )
    }
    #expect(await state.chunks.isEmpty)
    #expect(await state.hypothesisRequests.isEmpty)
}

@Test("Cancelling live transcription keeps the healthy helper warm")
func retainedLiveCancellationKeepsHelperWarm() async throws {
    let state = FakeLiveRuntimeState()
    let engine = makeLiveEngine(state: state)
    let first = try await engine.startLiveTranscription(
        sessionID: UUID(),
        controllerGeneration: UUID(),
        request: .init()
    )

    await engine.cancelLiveTranscription(session: first)
    let second = try await engine.startLiveTranscription(
        sessionID: UUID(),
        controllerGeneration: UUID(),
        request: .init()
    )

    #expect(second != first)
    #expect(await state.cancellations.count == 1)
    #expect(await state.loadCount == 1)
    #expect(await state.shutdownCount == 0)
}

@Test("Cancelling a finishing stream cannot trigger fallback or poison helper reuse")
func retainedLiveCancelDuringFinishIsPromptAndReusable() async throws {
    let state = FakeLiveRuntimeState()
    let engine = makeLiveEngine(state: state)
    let first = try await engine.startLiveTranscription(
        sessionID: UUID(),
        controllerGeneration: UUID(),
        request: .init()
    )
    await state.blockNextFinish()

    let finish = Task {
        try await engine.finishLiveTranscription(
            session: first,
            canonicalAudioURL: URL(fileURLWithPath: "/tmp/cancelled-finish.wav"),
            streamSummary: LivePCMStreamSummary(
                sampleCount: 0,
                byteCount: 0,
                frameCount: 0,
                fnv1a64: LivePCMDigest.fnv1a64OffsetBasis
            ),
            request: .init()
        )
    }
    for _ in 0..<200 {
        if await state.hasStartedFinish() { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(await state.hasStartedFinish())

    await engine.cancelLiveTranscription(session: first)
    await #expect(throws: CancellationError.self) {
        _ = try await finish.value
    }
    #expect(await state.fallbackCount == 0)
    #expect(await state.cancellations.count == 1)
    #expect(await state.shutdownCount == 0)

    let second = try await engine.startLiveTranscription(
        sessionID: UUID(),
        controllerGeneration: UUID(),
        request: .init()
    )
    #expect(second != first)
    #expect(await state.loadCount == 1)
    await engine.cancelLiveTranscription(session: second)
}

@Test("A provisional stream failure makes its canonical final fall back exactly once")
func retainedLiveFailureMakesCanonicalFinalFallbackOnce() async throws {
    let state = FakeLiveRuntimeState()
    let engine = makeLiveEngine(state: state)
    let live = try await engine.startLiveTranscription(
        sessionID: UUID(),
        controllerGeneration: UUID(),
        request: .init()
    )
    await state.setFailure(.append)

    await #expect(throws: FakeLiveRuntimeFailure.append) {
        try await engine.appendLiveAudio(
            LivePCMFrame(sequenceNumber: 0, sampleOffset: 0, pcmS16LE: Data([4, 0])),
            session: live
        )
    }
    let final = try await engine.finishLiveTranscription(
        session: live,
        canonicalAudioURL: URL(fileURLWithPath: "/tmp/stream-failed.wav"),
        streamSummary: LivePCMStreamSummary(
            sampleCount: 1,
            byteCount: 2,
            frameCount: 1,
            fnv1a64: 99
        ),
        request: .init()
    )

    #expect(final.text == "fallback-stream-failed")
    #expect(await state.fallbackCount == 1)
    #expect(await state.shutdownCount == 1)
    #expect(await state.finishRequests.isEmpty)
}

@Test("Authoritative finish supersedes one in-flight hypothesis without invalidating the helper")
func retainedLiveFinishSupersedesInFlightHypothesis() async throws {
    let state = FakeLiveRuntimeState()
    let engine = makeLiveEngine(state: state)
    let frame = LivePCMFrame(
        sequenceNumber: 0,
        sampleOffset: 0,
        pcmS16LE: Data([1, 0])
    )
    let live = try await engine.startLiveTranscription(
        sessionID: UUID(),
        controllerGeneration: UUID(),
        request: .init()
    )
    try await engine.appendLiveAudio(frame, session: live)
    await state.blockNextHypothesis()

    let preview = Task {
        try await engine.requestLiveHypothesis(
            session: live,
            revision: 1,
            decodedAudioWatermark: 1
        )
    }
    while !(await state.hasStartedHypothesis()) {
        await Task.yield()
    }

    let final = try await engine.finishLiveTranscription(
        session: live,
        canonicalAudioURL: URL(fileURLWithPath: "/tmp/superseded-preview.wav"),
        streamSummary: liveSummary(for: frame),
        request: .init()
    )
    await #expect(throws: RetainedWhisperRuntimeError.staleResponse) {
        _ = try await preview.value
    }

    #expect(final.text == "authoritative live final")
    #expect(await state.finishRequests.count == 1)
    #expect(await state.fallbackCount == 0)
    #expect(await state.shutdownCount == 0)
}

@Test("PCM append remains available while one provisional hypothesis is in flight")
func retainedLiveAppendRunsDuringInFlightHypothesis() async throws {
    let state = FakeLiveRuntimeState()
    let engine = makeLiveEngine(state: state)
    let frame = LivePCMFrame(
        sequenceNumber: 0,
        sampleOffset: 0,
        pcmS16LE: Data([7, 0, 8, 0])
    )
    let live = try await engine.startLiveTranscription(
        sessionID: UUID(),
        controllerGeneration: UUID(),
        request: .init()
    )
    await state.blockNextHypothesis()
    let preview = Task {
        try await engine.requestLiveHypothesis(
            session: live,
            revision: 1,
            decodedAudioWatermark: 0
        )
    }
    while !(await state.hasStartedHypothesis()) {
        await Task.yield()
    }

    try await engine.appendLiveAudio(frame, session: live)
    #expect(await state.chunks.count == 1)

    let final = try await engine.finishLiveTranscription(
        session: live,
        canonicalAudioURL: URL(fileURLWithPath: "/tmp/append-during-preview.wav"),
        streamSummary: liveSummary(for: frame),
        request: .init()
    )
    await #expect(throws: RetainedWhisperRuntimeError.staleResponse) {
        _ = try await preview.value
    }

    #expect(final.text == "authoritative live final")
    #expect(await state.fallbackCount == 0)
    #expect(await state.shutdownCount == 0)
}

@Test("Authoritative finish supersedes one in-flight append without invalidating the helper")
func retainedLiveFinishSupersedesInFlightAppend() async throws {
    let state = FakeLiveRuntimeState()
    let engine = makeLiveEngine(state: state)
    let frame = LivePCMFrame(
        sequenceNumber: 0,
        sampleOffset: 0,
        pcmS16LE: Data([1, 0])
    )
    let live = try await engine.startLiveTranscription(
        sessionID: UUID(),
        controllerGeneration: UUID(),
        request: .init()
    )
    await state.blockNextAppend()

    let append = Task {
        try await engine.appendLiveAudio(frame, session: live)
    }
    while !(await state.hasStartedAppend()) {
        await Task.yield()
    }

    let final = try await engine.finishLiveTranscription(
        session: live,
        canonicalAudioURL: URL(fileURLWithPath: "/tmp/superseded-append.wav"),
        streamSummary: liveSummary(for: frame),
        request: .init()
    )
    await #expect(throws: RetainedWhisperRuntimeError.staleResponse) {
        try await append.value
    }

    #expect(final.text == "authoritative live final")
    #expect(await state.finishRequests.count == 1)
    #expect(await state.fallbackCount == 0)
    #expect(await state.shutdownCount == 0)
}

@Test("Unload cancels live work, invalidates its generation, and reloads later")
func retainedLiveUnloadRejectsOldGenerationAndReloads() async throws {
    let state = FakeLiveRuntimeState()
    let engine = makeLiveEngine(state: state)
    let old = try await engine.startLiveTranscription(
        sessionID: UUID(),
        controllerGeneration: UUID(),
        request: .init()
    )

    await engine.unloadRetainedResources()

    await #expect(throws: RetainedWhisperRuntimeError.staleResponse) {
        try await engine.appendLiveAudio(
            LivePCMFrame(sequenceNumber: 0, sampleOffset: 0, pcmS16LE: Data([0, 0])),
            session: old
        )
    }
    let restarted = try await engine.startLiveTranscription(
        sessionID: UUID(),
        controllerGeneration: UUID(),
        request: .init()
    )
    #expect(restarted.runtimeGeneration != old.runtimeGeneration)
    #expect(await state.cancellations.count == 1)
    #expect(await state.shutdownCount == 1)
    #expect(await state.loadCount == 2)
}

@Test("Exhausted canonical fallback is terminal and cannot re-enter ordinary transcription")
func retainedLiveExhaustedFallbackIsExactlyOnce() async throws {
    let state = FakeLiveRuntimeState()
    let engine = makeLiveEngine(state: state)
    let canonicalURL = URL(
        fileURLWithPath: "/tmp/exhausted-final-\(UUID().uuidString).wav"
    )
    let live = try await engine.startLiveTranscription(
        sessionID: UUID(),
        controllerGeneration: UUID(),
        request: .init()
    )
    await state.setFailure(.finish)
    await state.setFallbackFailure(true)

    await #expect(throws: LiveTranscriptionFinalizationError.authoritativeFallbackExhausted) {
        _ = try await engine.finishLiveTranscription(
            session: live,
            canonicalAudioURL: canonicalURL,
            streamSummary: LivePCMStreamSummary(
                sampleCount: 0,
                byteCount: 0,
                frameCount: 0,
                fnv1a64: LivePCMDigest.fnv1a64OffsetBasis
            ),
            request: .init()
        )
    }

    // This mirrors the coordinator's current generic-catch retry. The engine
    // rejects it at the ownership boundary without loading or invoking either
    // inference path a second time.
    await #expect(throws: LiveTranscriptionFinalizationError.authoritativeFallbackExhausted) {
        _ = try await engine.transcribe(audioURL: canonicalURL, request: .init())
    }

    #expect(await state.finishAttemptCount == 1)
    #expect(await state.fallbackCount == 1)
    #expect(await state.oneShotRequests.isEmpty)
    #expect(await state.loadCount == 1)
    #expect(await state.shutdownCount == 1)
}

private func makeLiveEngine(state: FakeLiveRuntimeState) -> RetainedWhisperTranscriptionEngine {
    RetainedWhisperTranscriptionEngine(
        configuration: liveConfiguration(),
        sessionFactory: FakeLiveRuntimeFactory(state: state),
        fallback: FakeLiveFallbackEngine(state: state)
    )
}

private func liveConfiguration(
    vadModelPath: URL? = URL(fileURLWithPath: "/tmp/vad.bin")
) -> RetainedWhisperTranscriptionConfiguration {
    RetainedWhisperTranscriptionConfiguration(
        helperExecutableURL: URL(fileURLWithPath: "/tmp/steno-whisper-runtime"),
        modelPath: URL(fileURLWithPath: "/tmp/model.bin"),
        threadCount: 4,
        vadModelPath: vadModelPath,
        suppressNonSpeechTokens: true,
        suppressRegex: nil
    )
}

private func liveSummary(for frame: LivePCMFrame) -> LivePCMStreamSummary {
    LivePCMStreamSummary(
        sampleCount: UInt64(frame.sampleCount),
        byteCount: UInt64(frame.pcmS16LE.count),
        frameCount: 1,
        fnv1a64: LivePCMDigest.fnv1a64(frame.pcmS16LE)
    )
}

private func liveRichJSON(text: String) -> Data {
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return Data(
        """
        {
          "transcription": [
            {
              "offsets": { "from": 0, "to": 900 },
              "text": " \(escaped)",
              "tokens": [{ "text": " token", "p": 0.8 }]
            }
          ]
        }
        """.utf8
    )
}
