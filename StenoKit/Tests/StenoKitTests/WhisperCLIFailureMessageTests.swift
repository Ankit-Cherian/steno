import Foundation
import Testing
@testable import StenoKit

private let verboseFailureScript = """
#!/bin/sh
echo "whisper_init_from_file_with_params_no_state: loading model from '/Users/someone/Library/Application Support/Steno/models/ggml-small.en.bin'" >&2
echo "whisper_model_load: n_vocab = 51864" >&2
echo "error: failed to read audio file '/private/var/folders/xy/T/steno-capture.wav'" >&2
exit 3
"""

private func makeFailingCLI() throws -> (script: URL, audio: URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    let script = directory.appendingPathComponent("failing-whisper-\(UUID().uuidString).sh")
    try verboseFailureScript.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let audio = directory.appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audio)
    return (script, audio)
}

private struct UnavailableHelperFactory: WhisperRuntimeSessionFactory {
    func makeSession(configuration: RetainedWhisperTranscriptionConfiguration) async throws -> any WhisperRuntimeSession {
        throw RetainedWhisperRuntimeError.helperUnavailable
    }
}

private func expectPlainMessage(_ message: String) {
    #expect(message.count < 80, "\(message)")
    #expect(!message.contains("/"), "\(message)")
    #expect(!message.contains("whisper_"), "\(message)")
    #expect(!message.contains("\n"), "\(message)")
}

@Test("A whisper-cli failure shows a short message and keeps the full output for diagnosis")
func whisperCLIFailureMessageIsShort() async throws {
    let (script, audio) = try makeFailingCLI()
    defer {
        try? FileManager.default.removeItem(at: script)
        try? FileManager.default.removeItem(at: audio)
    }
    let engine = WhisperCLITranscriptionEngine(config: .init(
        whisperCLIPath: script,
        modelPath: URL(fileURLWithPath: "/tmp/steno-model.bin")
    ))

    do {
        _ = try await engine.transcribe(audioURL: audio, languageHints: ["en"])
        Issue.record("Expected the failing run to throw")
    } catch let error as WhisperCLITranscriptionError {
        expectPlainMessage(error.localizedDescription)
        guard case .failedToRun(let status, let stderr) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(status == 3)
        #expect(stderr.contains("failed to read audio file '/private/var/folders/xy/T/steno-capture.wav'"))
    }
}

@Test("The retained engine's fallback failure reaches the user as a short message")
func retainedFallbackFailureMessageIsShort() async throws {
    let (script, audio) = try makeFailingCLI()
    defer {
        try? FileManager.default.removeItem(at: script)
        try? FileManager.default.removeItem(at: audio)
    }
    let engine = RetainedWhisperTranscriptionEngine(
        configuration: .init(
            helperExecutableURL: URL(fileURLWithPath: "/tmp/steno-helper"),
            modelPath: URL(fileURLWithPath: "/tmp/steno-model.bin"),
            threadCount: 1,
            vadModelPath: nil,
            suppressNonSpeechTokens: true,
            suppressRegex: nil
        ),
        sessionFactory: UnavailableHelperFactory(),
        fallback: WhisperCLITranscriptionEngine(config: .init(
            whisperCLIPath: script,
            modelPath: URL(fileURLWithPath: "/tmp/steno-model.bin")
        ))
    )

    do {
        _ = try await engine.transcribe(audioURL: audio, request: .init())
        Issue.record("Expected the failing run to throw")
    } catch {
        expectPlainMessage(error.localizedDescription)
    }
    await engine.shutdown()
}
