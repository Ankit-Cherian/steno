import Foundation
import Testing
@testable import StenoKit

private actor SlowStartRuntimeLog {
    var loads = 0
    var shutdowns = 0
    var startEntered = false
    var cancelledStreams: [UUID] = []
    func load() { loads += 1 }
    func shutdown() { shutdowns += 1 }
    func enterStart() { startEntered = true }
    func cancel(_ id: UUID) { cancelledStreams.append(id) }
}

private struct SlowStartRuntimeFactory: WhisperRuntimeSessionFactory {
    let log: SlowStartRuntimeLog
    func makeSession(configuration: RetainedWhisperTranscriptionConfiguration) async throws -> any WhisperRuntimeSession {
        await log.load()
        return SlowStartRuntime(log: log)
    }
}

/// StreamStart takes a while, so a cancel can land while it is in flight.
private actor SlowStartRuntime: WhisperStreamingRuntimeSession {
    let log: SlowStartRuntimeLog
    init(log: SlowStartRuntimeLog) { self.log = log }

    func transcribe(_ request: WhisperRuntimeRequest) async throws -> Data {
        Data(#"{"transcription":[{"offsets":{"from":0,"to":900},"text":" warm","tokens":[{"text":" warm","p":0.9}]}]}"#.utf8)
    }

    func startStream(id: UUID, generation: UInt64, configuration: WhisperStreamConfiguration) async throws -> LiveTranscriptionRuntimeIdentity {
        await log.enterStart()
        try await Task.sleep(for: .seconds(5))
        return LiveTranscriptionRuntimeIdentity(
            protocolVersion: 2, runtimeIdentifier: "runtime", modelIdentifier: "model", vadIdentifier: "vad",
            currentASRContextCount: 1, peakASRContextCount: 1
        )
    }

    func append(_ chunk: WhisperStreamAudioChunk, streamID: UUID, generation: UInt64) async throws {}

    func requestHypothesis(streamID: UUID, generation: UInt64, revision: UInt64, watermark: UInt64) async throws -> WhisperStreamHypothesis {
        throw RetainedWhisperRuntimeError.unsupportedConfiguration
    }

    func finishStream(id: UUID, generation: UInt64, request: WhisperStreamFinishRequest) async throws -> Data {
        throw RetainedWhisperRuntimeError.unsupportedConfiguration
    }

    func cancelStream(id: UUID, generation: UInt64) async { await log.cancel(id) }
    func shutdown() async { await log.shutdown() }
}

private struct UnexpectedFallback: TranscriptionEngine {
    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        Issue.record("The warm helper should serve this request")
        return RawTranscript(text: "fallback")
    }
}

@Test("Cancelling a live start in flight keeps the warm helper loaded")
func cancelledLiveStartKeepsWarmHelper() async throws {
    let log = SlowStartRuntimeLog()
    let engine = RetainedWhisperTranscriptionEngine(
        configuration: .init(
            helperExecutableURL: URL(fileURLWithPath: "/tmp/steno-helper"),
            modelPath: URL(fileURLWithPath: "/tmp/steno-model.bin"),
            threadCount: 1,
            vadModelPath: URL(fileURLWithPath: "/tmp/steno-vad.bin"),
            suppressNonSpeechTokens: true,
            suppressRegex: nil
        ),
        sessionFactory: SlowStartRuntimeFactory(log: log),
        fallback: UnexpectedFallback()
    )
    _ = try await engine.transcribe(audioURL: URL(fileURLWithPath: "/tmp/warm.wav"), request: .init())
    #expect(await log.loads == 1)

    let start = Task {
        try await engine.startLiveTranscription(
            sessionID: SessionID(), controllerGeneration: UUID(), request: .init()
        )
    }
    for _ in 0..<400 where !(await log.startEntered) {
        try await Task.sleep(for: .milliseconds(5))
    }
    start.cancel()
    await #expect(throws: CancellationError.self) { _ = try await start.value }

    let after = try await engine.transcribe(audioURL: URL(fileURLWithPath: "/tmp/after.wav"), request: .init())
    #expect(after.text == "warm")
    #expect(await log.shutdowns == 0)
    #expect(await log.loads == 1)
    await engine.shutdown()
}
