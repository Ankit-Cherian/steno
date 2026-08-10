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
    let extraArguments = WhisperRuntimeConfiguration.additionalArguments(
        threadCount: 6,
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
    let retained = RetainedWhisperTranscriptionEngine(
        configuration: RetainedWhisperTranscriptionConfiguration(
            helperExecutableURL: URL(fileURLWithPath: helperPath),
            modelPath: URL(fileURLWithPath: modelPath),
            threadCount: 6,
            vadModelPath: vadPath,
            suppressNonSpeechTokens: true,
            suppressRegex: nil,
            beamSize: 5,
            bestOf: 5
        ),
        fallback: cli
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
        }
    }
    await retained.shutdown()
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
