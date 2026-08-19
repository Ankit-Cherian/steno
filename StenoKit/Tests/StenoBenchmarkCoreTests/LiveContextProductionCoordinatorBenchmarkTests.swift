import Foundation
import StenoKit
import Testing
@testable import StenoBenchmarkCore

@Test("Production coordinator stop benchmark includes final, insertion, and history")
func productionCoordinatorStopBenchmarkMeasuresWholeCompletionPath() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-production-stop-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixtureURL = directory.appendingPathComponent("public-canonical.wav")
    let fixtureData = makeProductionBenchmarkWAV(sampleCount: 8_000)
    try fixtureData.write(to: fixtureURL)

    let finalGate = ProductionBenchmarkTestGate()
    let engine = ProductionBenchmarkFakeLiveEngine(finalGate: finalGate)
    let completion = ProductionBenchmarkCompletionProbe()
    let task = Task {
        let result = try await LiveContextProductionCoordinatorBenchmark.run(
            engine: engine,
            publicCanonicalWAVURL: fixtureURL,
            publicFixtureAttested: true,
            alternatingTrialCount: 2,
            languageHints: ["en-US"],
            liveStartTimeout: .seconds(1)
        )
        await completion.markReturned()
        return result
    }

    await finalGate.waitUntilBlocked()
    try await Task.sleep(for: .milliseconds(40))
    #expect(await completion.hasReturned == false)
    await finalGate.release()

    let result = try await task.value
    #expect(await completion.hasReturned)
    #expect(result.definition == LiveContextProductionCoordinatorBenchmark.definition)
    #expect(result.trialLivePreviewOrder == [true, false])
    #expect(result.trials.map(\.index) == [0, 1])
    #expect(result.trials.map(\.livePreviewEnabled) == [true, false])
    #expect(result.enabledStopToAuthoritativeInsertionAndHistoryMS.count == 1)
    #expect(result.disabledStopToAuthoritativeInsertionAndHistoryMS.count == 1)
    #expect(result.enabledStopToAuthoritativeInsertionAndHistoryMS[0] >= 35)
    #expect(result.authoritativeFinalOwnershipCount == 2)
    #expect(result.insertionCommitCount == 2)
    #expect(result.historyAppendCount == 2)
    #expect(result.trials.allSatisfy { $0.insertionStatus == .inserted })
    let enabledCanonicalPCM = try #require(result.trials[0].canonicalPCM)
    #expect(enabledCanonicalPCM.sampleCount == 8_000)
    #expect(enabledCanonicalPCM.byteCount == 16_000)
    #expect(result.trials[1].canonicalPCM == nil)
    #expect(result.publicFixtureSHA256.count == 64)
    #expect(result.configurationSHA256.count == 64)
    #expect(result.languageHints == ["en-US"])
    #expect(result.enabledReadinessDefinition == LiveContextProductionCoordinatorBenchmark.enabledReadinessDefinition)
    #expect(result.successfulEnabledReadinessCount == 1)
    #expect(result.liveFinishAuthoritativeFinalCount == 1)
    #expect(result.disabledTranscribeAuthoritativeFinalCount == 1)
    #expect(result.coordinatorFallbackCount == 0)
    #expect(result.observedLiveRuntimeIdentities.count == 1)
    #expect(await engine.finishCount == 1)
    #expect(await engine.transcribeCount == 1)
    #expect(await engine.hypothesisCount >= 1)
    #expect(await engine.finishSummary == enabledCanonicalPCM)

    // SessionCoordinator receives only per-trial copies. Its normal cleanup
    // must never delete or mutate the source fixture.
    #expect(FileManager.default.fileExists(atPath: fixtureURL.path))
    #expect(try Data(contentsOf: fixtureURL) == fixtureData)
}

@Test("Production coordinator stop benchmark rejects private or unbalanced inputs before capture")
func productionCoordinatorStopBenchmarkRejectsUnsafeConfiguration() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-production-stop-rejection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixtureURL = directory.appendingPathComponent("fixture.wav")
    try makeProductionBenchmarkWAV(sampleCount: 16).write(to: fixtureURL)
    let engine = ProductionBenchmarkFakeLiveEngine(finalGate: nil)

    await #expect(throws: LiveContextProductionCoordinatorBenchmark.BenchmarkError.publicFixtureAttestationRequired) {
        try await LiveContextProductionCoordinatorBenchmark.run(
            engine: engine,
            publicCanonicalWAVURL: fixtureURL,
            publicFixtureAttested: false,
            alternatingTrialCount: 2
        )
    }
    await #expect(throws: LiveContextProductionCoordinatorBenchmark.BenchmarkError.invalidTrialCount) {
        try await LiveContextProductionCoordinatorBenchmark.run(
            engine: engine,
            publicCanonicalWAVURL: fixtureURL,
            publicFixtureAttested: true,
            alternatingTrialCount: 3
        )
    }
    #expect(await engine.beginCount == 0)
}

private actor ProductionBenchmarkCompletionProbe {
    private(set) var hasReturned = false
    func markReturned() { hasReturned = true }
}

private actor ProductionBenchmarkTestGate {
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        blocked = true
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor ProductionBenchmarkFakeLiveEngine: LiveTranscriptionEngine {
    private let finalGate: ProductionBenchmarkTestGate?
    private(set) var beginCount = 0
    private(set) var finishCount = 0
    private(set) var transcribeCount = 0
    private(set) var hypothesisCount = 0
    private(set) var finishSummary: LivePCMStreamSummary?

    init(finalGate: ProductionBenchmarkTestGate?) {
        self.finalGate = finalGate
    }

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        _ = audioURL
        _ = request
        transcribeCount += 1
        return RawTranscript(text: "authoritative disabled final", durationMS: 100)
    }

    func startLiveTranscription(
        sessionID: SessionID,
        controllerGeneration: UUID,
        request: TranscriptionRequest
    ) async throws -> LiveTranscriptionSession {
        _ = request
        beginCount += 1
        return LiveTranscriptionSession(
            sessionID: sessionID,
            controllerGeneration: controllerGeneration,
            runtimeGeneration: 1,
            runtimeIdentity: LiveTranscriptionRuntimeIdentity(
                protocolVersion: 2,
                runtimeIdentifier: "production-benchmark-test-runtime",
                modelIdentifier: "production-benchmark-test-model",
                vadIdentifier: nil,
                currentASRContextCount: 1,
                peakASRContextCount: 1
            )
        )
    }

    func appendLiveAudio(
        _ frame: LivePCMFrame,
        session: LiveTranscriptionSession
    ) async throws {
        _ = frame
        _ = session
    }

    func requestLiveHypothesis(
        session: LiveTranscriptionSession,
        revision: UInt64,
        decodedAudioWatermark: UInt64
    ) async throws -> LiveTranscriptionEvent {
        hypothesisCount += 1
        return LiveTranscriptionEvent(
            session: session,
            revision: revision,
            decodedAudioWatermark: decodedAudioWatermark,
            emittedAtMonotonicNanos: 1,
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
        _ = session
        _ = canonicalAudioURL
        _ = streamSummary
        _ = request
        finishCount += 1
        finishSummary = streamSummary
        await finalGate?.block()
        return RawTranscript(text: "authoritative enabled final", durationMS: 100)
    }

    func cancelLiveTranscription(session: LiveTranscriptionSession) async {
        _ = session
    }
}

private func makeProductionBenchmarkWAV(sampleCount: Int) -> Data {
    let byteCount = sampleCount * MemoryLayout<Int16>.size
    var data = Data()
    data.append(contentsOf: Array("RIFF".utf8))
    appendProductionBenchmarkUInt32(UInt32(36 + byteCount), to: &data)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    appendProductionBenchmarkUInt32(16, to: &data)
    appendProductionBenchmarkUInt16(1, to: &data)
    appendProductionBenchmarkUInt16(1, to: &data)
    appendProductionBenchmarkUInt32(16_000, to: &data)
    appendProductionBenchmarkUInt32(32_000, to: &data)
    appendProductionBenchmarkUInt16(2, to: &data)
    appendProductionBenchmarkUInt16(16, to: &data)
    data.append(contentsOf: Array("data".utf8))
    appendProductionBenchmarkUInt32(UInt32(byteCount), to: &data)
    for index in 0..<sampleCount {
        appendProductionBenchmarkUInt16(UInt16(bitPattern: Int16(index % 127)), to: &data)
    }
    return data
}

private func appendProductionBenchmarkUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
}

private func appendProductionBenchmarkUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 24) & 0xff))
}
