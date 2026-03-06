import Foundation
import Testing
@testable import StenoKit

@Test("Engine forwards additional arguments including --suppress-nst and --vad flags")
func vadFlagForwardingWithModel() async throws {
    let argsFile = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vad-args-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: argsFile) }

    let scriptURL = try makeVADTestScript(argsFile: argsFile)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    // Simulate a real VAD model file
    let vadModelPath = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fake-vad-model-\(UUID().uuidString).bin")
    try Data().write(to: vadModelPath)
    defer { try? FileManager.default.removeItem(at: vadModelPath) }

    let engine = WhisperCLITranscriptionEngine(
        config: .init(
            whisperCLIPath: scriptURL,
            modelPath: URL(fileURLWithPath: "/tmp/fake-model.bin"),
            additionalArguments: ["-t", "4", "--suppress-nst", "--vad", "--vad-model", vadModelPath.path]
        )
    )

    let result = try await engine.transcribe(audioURL: audioURL, languageHints: ["en"])
    #expect(result.text == "ok")

    let args = try String(contentsOf: argsFile, encoding: .utf8)
    #expect(args.contains("--suppress-nst"))
    #expect(args.contains("--vad"))
    #expect(args.contains("--vad-model"))
    #expect(args.contains(vadModelPath.path))
}

@Test("Engine forwards --suppress-nst but not --vad when VAD model is absent")
func vadFlagForwardingWithoutModel() async throws {
    let argsFile = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vad-args-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: argsFile) }

    let scriptURL = try makeVADTestScript(argsFile: argsFile)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    // Only pass --suppress-nst, no --vad flags (simulating missing model)
    let engine = WhisperCLITranscriptionEngine(
        config: .init(
            whisperCLIPath: scriptURL,
            modelPath: URL(fileURLWithPath: "/tmp/fake-model.bin"),
            additionalArguments: ["-t", "4", "--suppress-nst"]
        )
    )

    let result = try await engine.transcribe(audioURL: audioURL, languageHints: ["en"])
    #expect(result.text == "ok")

    let args = try String(contentsOf: argsFile, encoding: .utf8)
    #expect(args.contains("--suppress-nst"))
    #expect(!args.contains("--vad"))
    #expect(!args.contains("--vad-model"))
}

private func makeVADTestScript(argsFile: URL) throws -> URL {
    let body = """
    #!/bin/sh
    output_base=""
    all_args="$*"
    printf "%s" "$all_args" > "\(argsFile.path)"
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "-of" ]; then
        shift
        output_base="$1"
      fi
      shift
    done
    printf "ok" > "${output_base}.txt"
    exit 0
    """

    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fake-whisper-vad-\(UUID().uuidString).sh")
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o755))],
        ofItemAtPath: url.path
    )
    return url
}
