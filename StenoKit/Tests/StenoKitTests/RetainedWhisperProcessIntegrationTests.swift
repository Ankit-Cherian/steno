import Foundation
import Testing
@testable import StenoKit

@Test("Retained process runtime matches the one-shot CLI transcript contract when fixtures are declared")
func retainedProcessRuntimeMatchesCLIContract() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let helperPath = environment["STENO_TEST_RETAINED_HELPER"],
          let cliPath = environment["STENO_TEST_WHISPER_CLI"],
          let modelPath = environment["STENO_TEST_WHISPER_MODEL"],
          let audioPath = environment["STENO_TEST_WHISPER_AUDIO"]
    else {
        return
    }

    let vadPath = environment["STENO_TEST_WHISPER_VAD"].map(URL.init(fileURLWithPath:))
    // The helper and the CLI must use the same count for their outputs to match.
    let threadCount = try integrationThreadCount(default: 6)
    let extraArguments = WhisperRuntimeConfiguration.additionalArguments(
        threadCount: threadCount,
        vadEnabled: vadPath != nil,
        vadModelPath: vadPath?.path ?? ""
    )
    let cli = WhisperCLITranscriptionEngine(
        config: .init(
            whisperCLIPath: URL(fileURLWithPath: cliPath),
            modelPath: URL(fileURLWithPath: modelPath),
            additionalArguments: extraArguments
        )
    )
    // The retained engine falls back to the CLI on a helper error, which would
    // make this comparison pass without the helper. Count those fallbacks.
    let fallbackState = IntegrationFallbackState()
    let retained = RetainedWhisperTranscriptionEngine(
        configuration: RetainedWhisperTranscriptionConfiguration(
            helperExecutableURL: URL(fileURLWithPath: helperPath),
            modelPath: URL(fileURLWithPath: modelPath),
            threadCount: threadCount,
            vadModelPath: vadPath,
            suppressNonSpeechTokens: true,
            suppressRegex: nil,
            beamSize: 5,
            bestOf: 5
        ),
        fallback: RecordingFallbackEngine(state: fallbackState, inner: cli)
    )
    let request = TranscriptionRequest(
        languageHints: [environment["STENO_TEST_WHISPER_LANGUAGE"] ?? "en-US"],
        appContext: AppContext(
            bundleIdentifier: "com.example.editor",
            appName: "Editor",
            isIDE: false
        ),
        hotTerms: ["TURSO"]
    )
    let audioURL = URL(fileURLWithPath: audioPath)
    let expected = try await cli.transcribe(audioURL: audioURL, request: request)
    if environment["STENO_TEST_WHISPER_EXPECT_EMPTY"] == "1" {
        #expect(expected.text.isEmpty)
        #expect(expected.segments.isEmpty)
    }
    let repetitions = max(1, Int(environment["STENO_TEST_WHISPER_REPETITIONS"] ?? "") ?? 20)
    for _ in 0..<repetitions {
        let actual = try await retained.transcribe(audioURL: audioURL, request: request)
        assertTranscriptContract(actual, matches: expected)
        if environment["STENO_TEST_WHISPER_EXPECT_EMPTY"] == "1" {
            #expect(actual.text.isEmpty)
            #expect(actual.segments.isEmpty)
        } else if requiresRetainedHelper {
            #expect(!actual.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    await retained.shutdown()
    if requiresRetainedHelper {
        #expect(await fallbackState.count == 0, "the retained helper did not serve every request")
    }
}

@Test("Retained engine streams real speech through the real helper to one final transcript")
func retainedProcessRuntimeStreamsSpeechToOneFinal() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard requiresRetainedHelper,
          environment["STENO_TEST_WHISPER_EXPECT_EMPTY"] != "1",
          let helperPath = environment["STENO_TEST_RETAINED_HELPER"],
          let modelPath = environment["STENO_TEST_WHISPER_MODEL"],
          let audioPath = environment["STENO_TEST_WHISPER_AUDIO"],
          let vadPath = environment["STENO_TEST_WHISPER_VAD"]
    else {
        return
    }

    let fallbackState = IntegrationFallbackState()
    let engine = RetainedWhisperTranscriptionEngine(
        configuration: RetainedWhisperTranscriptionConfiguration(
            helperExecutableURL: URL(fileURLWithPath: helperPath),
            modelPath: URL(fileURLWithPath: modelPath),
            threadCount: try integrationThreadCount(default: 4),
            vadModelPath: URL(fileURLWithPath: vadPath),
            suppressNonSpeechTokens: true,
            suppressRegex: nil
        ),
        fallback: IntegrationFallbackEngine(state: fallbackState)
    )
    let request = TranscriptionRequest(languageHints: ["en-US"])
    let sessionID = SessionID()
    let audioURL = URL(fileURLWithPath: audioPath)

    let session = try await engine.startLiveTranscription(
        sessionID: sessionID,
        controllerGeneration: UUID(),
        request: request
    )
    // Stream the WAV the way capture does: bounded frames from the canonical file.
    let streamer = try CanonicalWAVFrameStreamer(sessionID: sessionID, audioURL: audioURL)
    var poll = try await streamer.finalize(sessionID: sessionID)
    var appendedFrames = 0
    while true {
        for frame in poll.frames {
            try await engine.appendLiveAudio(frame, session: session)
            appendedFrames += 1
        }
        guard case .draining = poll.state else { break }
        poll = try await streamer.drain(sessionID: sessionID)
    }
    guard case let .finalized(summary) = poll.state else {
        Issue.record("the speech sample did not stream to completion: \(poll.state)")
        await engine.shutdown()
        return
    }
    #expect(appendedFrames > 1)
    #expect(summary.frameCount == UInt64(appendedFrames))

    let final = try await engine.finishLiveTranscription(
        session: session,
        canonicalAudioURL: audioURL,
        streamSummary: summary,
        request: request
    )
    #expect(!final.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    // The stream is closed: a second finish must not produce another final.
    await #expect(throws: (any Error).self) {
        _ = try await engine.finishLiveTranscription(
            session: session,
            canonicalAudioURL: audioURL,
            streamSummary: summary,
            request: request
        )
    }
    await engine.shutdown()
    #expect(await fallbackState.count == 0, "the stream final came from the fallback, not the helper")
}

@Test("Missing and corrupt models fail closed through one fallback")
func retainedProcessRuntimeFailsClosedForInvalidModels() async throws {
    guard let helperPath = ProcessInfo.processInfo.environment["STENO_TEST_RETAINED_HELPER"] else {
        return
    }

    let fallbackState = IntegrationFallbackState()
    let fallback = IntegrationFallbackEngine(state: fallbackState)
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-runtime-model-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let corruptModel = temporaryDirectory.appendingPathComponent("corrupt.bin")
    try Data("not-a-whisper-model".utf8).write(to: corruptModel)
    let modelPaths = [
        temporaryDirectory.appendingPathComponent("missing.bin"),
        corruptModel,
    ]

    for (index, modelPath) in modelPaths.enumerated() {
        let engine = RetainedWhisperTranscriptionEngine(
            configuration: RetainedWhisperTranscriptionConfiguration(
                helperExecutableURL: URL(fileURLWithPath: helperPath),
                modelPath: modelPath,
                threadCount: 2,
                vadModelPath: nil,
                suppressNonSpeechTokens: true,
                suppressRegex: nil
            ),
            fallback: fallback
        )
        let result = try await engine.transcribe(
            audioURL: temporaryDirectory.appendingPathComponent("unused-\(index).wav"),
            request: .init()
        )
        #expect(result.text == "fallback")
        await engine.shutdown()
    }

    #expect(await fallbackState.count == modelPaths.count)
}

@Test("Retained helper rejects an unknown language like the one-shot CLI")
func retainedProcessRuntimeRejectsUnknownLanguage() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let helperPath = environment["STENO_TEST_RETAINED_HELPER"],
          let cliPath = environment["STENO_TEST_WHISPER_CLI"],
          let modelPath = environment["STENO_TEST_WHISPER_MODEL"],
          let audioPath = environment["STENO_TEST_WHISPER_AUDIO"]
    else {
        return
    }

    let configuration = RetainedWhisperTranscriptionConfiguration(
        helperExecutableURL: URL(fileURLWithPath: helperPath),
        modelPath: URL(fileURLWithPath: modelPath),
        threadCount: 2,
        vadModelPath: nil,
        suppressNonSpeechTokens: true,
        suppressRegex: nil
    )
    let session = try await ProcessWhisperRuntimeSessionFactory()
        .makeSession(configuration: configuration)
    defer { Task { await session.shutdown() } }

    await #expect(throws: RetainedWhisperRuntimeError.self) {
        _ = try await session.transcribe(
            WhisperRuntimeRequest(
                id: UUID(),
                generation: 0,
                audioURL: URL(fileURLWithPath: audioPath),
                language: "not-a-language",
                prompt: nil,
                threadCount: 2,
                suppressNonSpeechTokens: true,
                suppressRegex: nil,
                vadModelPath: nil,
                beamSize: 5,
                bestOf: 5
            )
        )
    }

    let cli = WhisperCLITranscriptionEngine(
        config: .init(
            whisperCLIPath: URL(fileURLWithPath: cliPath),
            modelPath: URL(fileURLWithPath: modelPath)
        )
    )
    await #expect(throws: WhisperCLITranscriptionError.self) {
        _ = try await cli.transcribe(
            audioURL: URL(fileURLWithPath: audioPath),
            request: TranscriptionRequest(languageHints: ["not-a-language"])
        )
    }
}

/// Set where the real helper must serve requests; any fallback then fails the test.
private var requiresRetainedHelper: Bool {
    ProcessInfo.processInfo.environment["STENO_TEST_REQUIRE_RETAINED_HELPER"] == "1"
}

/// Runners with few CPUs can lower the request with STENO_TEST_WHISPER_THREADS.
private func integrationThreadCount(default defaultCount: Int) throws -> Int {
    guard let configured = ProcessInfo.processInfo.environment["STENO_TEST_WHISPER_THREADS"] else {
        return defaultCount
    }
    guard let count = Int(configured), (1...64).contains(count) else {
        throw IntegrationConfigurationError.invalidThreadCount(configured)
    }
    return count
}

private enum IntegrationConfigurationError: Error {
    case invalidThreadCount(String)
}

private actor IntegrationFallbackState {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private struct IntegrationFallbackEngine: TranscriptionEngine {
    let state: IntegrationFallbackState

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        _ = audioURL
        _ = request
        await state.record()
        return RawTranscript(text: "fallback")
    }
}

/// Records each fallback, then delegates so the comparison can still complete.
private struct RecordingFallbackEngine: TranscriptionEngine {
    let state: IntegrationFallbackState
    let inner: any TranscriptionEngine

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        await state.record()
        return try await inner.transcribe(audioURL: audioURL, request: request)
    }
}

private func assertTranscriptContract(
    _ actual: RawTranscript,
    matches expected: RawTranscript
) {
    #expect(actual.text == expected.text)
    #expect(actual.durationMS == expected.durationMS)
    #expect(actual.segments.count == expected.segments.count)
    for (actualSegment, expectedSegment) in zip(actual.segments, expected.segments) {
        #expect(actualSegment.startMS == expectedSegment.startMS)
        #expect(actualSegment.endMS == expectedSegment.endMS)
        #expect(actualSegment.text == expectedSegment.text)
        if let actualConfidence = actualSegment.confidence,
           let expectedConfidence = expectedSegment.confidence {
            #expect(abs(actualConfidence - expectedConfidence) < 0.000_001)
        } else {
            #expect(actualSegment.confidence == expectedSegment.confidence)
        }
    }
    if let actualConfidence = actual.avgConfidence,
       let expectedConfidence = expected.avgConfidence {
        #expect(abs(actualConfidence - expectedConfidence) < 0.000_001)
    } else {
        #expect(actual.avgConfidence == expected.avgConfidence)
    }
}
