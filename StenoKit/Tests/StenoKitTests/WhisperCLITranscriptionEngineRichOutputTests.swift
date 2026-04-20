import Foundation
import Testing
@testable import StenoKit

@Test("WhisperCLITranscriptionEngine prefers JSON-full output and populates transcript metadata")
func whisperCLITranscriptionEnginePrefersJSONFullOutput() async throws {
    let scriptURL = try makeExecutableWhisperScript(
        """
        #!/bin/sh
        output_base=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-of" ]; then
            shift
            output_base="$1"
          fi
          shift
        done
        if [ -z "$output_base" ]; then
          echo "missing -of" >&2
          exit 2
        fi
        cat > "${output_base}.json" <<'EOF'
        {
          "result": { "language": "en" },
          "transcription": [
            {
              "offsets": { "from": 0, "to": 1200 },
              "text": " hello world",
              "tokens": [
                { "text": " hello", "p": 0.9, "offsets": { "from": 0, "to": 500 } },
                { "text": " world", "p": 0.6, "offsets": { "from": 500, "to": 1200 } }
              ]
            },
            {
              "offsets": { "from": 1200, "to": 2000 },
              "text": " again",
              "tokens": [
                { "text": " again", "p": 0.8, "offsets": { "from": 1200, "to": 2000 } }
              ]
            }
          ]
        }
        EOF
        printf "fallback should not win\\n" > "${output_base}.txt"
        exit 0
        """
    )
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let audioURL = try makeTemporaryAudioFile()
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let engine = WhisperCLITranscriptionEngine(
        config: .init(
            whisperCLIPath: scriptURL,
            modelPath: URL(fileURLWithPath: "/tmp/fake-model.bin")
        )
    )

    let result = try await engine.transcribe(
        audioURL: audioURL,
        request: .init(languageHints: ["en-US"])
    )

    #expect(result.text == "hello world again")
    #expect(result.durationMS == 2_000)
    #expect(result.segments.count == 2)
    #expect(result.segments[0].startMS == 0)
    #expect(result.segments[0].endMS == 1_200)
    #expect(result.segments[0].text == "hello world")
    #expect(result.segments[1].startMS == 1_200)
    #expect(result.segments[1].endMS == 2_000)
    #expect(result.segments[1].text == "again")
    #expect(abs((result.segments[0].confidence ?? 0) - 0.75) < 0.0001)
    #expect(abs((result.segments[1].confidence ?? 0) - 0.8) < 0.0001)
    #expect(abs((result.avgConfidence ?? 0) - (2.3 / 3.0)) < 0.0001)
}

@Test("WhisperCLITranscriptionEngine falls back to txt when rich JSON is unavailable")
func whisperCLITranscriptionEngineFallsBackToTXTWhenJSONUnavailable() async throws {
    let scriptURL = try makeExecutableWhisperScript(
        """
        #!/bin/sh
        output_base=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-of" ]; then
            shift
            output_base="$1"
          fi
          shift
        done
        if [ -z "$output_base" ]; then
          echo "missing -of" >&2
          exit 2
        fi
        printf "{ not valid json }\\n" > "${output_base}.json"
        printf " fallback transcript from txt \\n" > "${output_base}.txt"
        exit 0
        """
    )
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let audioURL = try makeTemporaryAudioFile()
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let engine = WhisperCLITranscriptionEngine(
        config: .init(
            whisperCLIPath: scriptURL,
            modelPath: URL(fileURLWithPath: "/tmp/fake-model.bin")
        )
    )

    let result = try await engine.transcribe(
        audioURL: audioURL,
        request: .init(languageHints: ["en"])
    )

    #expect(result.text == "fallback transcript from txt")
    #expect(result.segments.isEmpty)
    #expect(result.avgConfidence == nil)
}

@Test("WhisperCLITranscriptionEngine passes prompt and suppress regex steering arguments")
func whisperCLITranscriptionEnginePassesPromptAndSuppressRegex() async throws {
    let scriptURL = try makeExecutableWhisperScript(
        """
        #!/bin/sh
        output_base=""
        for arg in "$@"; do
          if [ "$prev" = "-of" ]; then
            output_base="$arg"
          fi
          prev="$arg"
        done
        if [ -z "$output_base" ]; then
          echo "missing -of" >&2
          exit 2
        fi
        printf "%s " "$@" > "${output_base}.txt"
        exit 0
        """
    )
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let audioURL = try makeTemporaryAudioFile()
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let args = WhisperRuntimeConfiguration.additionalArguments(
        threadCount: 4,
        vadEnabled: false,
        vadModelPath: "/tmp/missing-vad.bin",
        suppressRegex: #"\[(?:MUSIC|NOISE)\]"#,
        pathExists: { _ in false }
    )
    let engine = WhisperCLITranscriptionEngine(
        config: .init(
            whisperCLIPath: scriptURL,
            modelPath: URL(fileURLWithPath: "/tmp/fake-model.bin"),
            additionalArguments: args
        )
    )

    let result = try await engine.transcribe(
        audioURL: audioURL,
        request: .init(
            languageHints: ["en-US"],
            appContext: AppContext(bundleIdentifier: "com.todesktop.230313mzl4w4u92", appName: "Cursor", isIDE: true),
            hotTerms: ["TURSO", "StenoKit"]
        )
    )

    #expect(result.text.contains("--prompt"))
    #expect(result.text.contains("App: Cursor"))
    #expect(result.text.contains("Terms: TURSO, StenoKit"))
    #expect(result.text.contains("--suppress-regex"))
    #expect(result.text.contains(#"\[(?:MUSIC|NOISE)\]"#))
}

private func makeTemporaryAudioFile() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: url)
    return url
}

private func makeExecutableWhisperScript(_ body: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fake-whisper-rich-\(UUID().uuidString).sh")
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: url.path)
    return url
}
