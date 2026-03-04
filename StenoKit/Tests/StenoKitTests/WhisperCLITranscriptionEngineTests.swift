import Foundation
import Testing
@testable import StenoKit

@Test("WhisperCLITranscriptionEngine reads txt output on success")
func whisperCLITranscriptionEngineSuccess() async throws {
    let scriptURL = try makeExecutableScript(
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
        printf " hello from fake whisper \\n" > "${output_base}.txt"
        exit 0
        """
    )
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let engine = WhisperCLITranscriptionEngine(
        config: .init(
            whisperCLIPath: scriptURL,
            modelPath: URL(fileURLWithPath: "/tmp/fake-model.bin")
        )
    )

    let result = try await engine.transcribe(audioURL: audioURL, languageHints: ["en-US"])
    #expect(result.text == "hello from fake whisper")
}

@Test("WhisperCLITranscriptionEngine maps non-zero exits to failedToRun")
func whisperCLITranscriptionEngineFailureExitCode() async throws {
    let scriptURL = try makeExecutableScript(
        """
        #!/bin/sh
        echo "boom failure" >&2
        exit 42
        """
    )
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let engine = WhisperCLITranscriptionEngine(
        config: .init(
            whisperCLIPath: scriptURL,
            modelPath: URL(fileURLWithPath: "/tmp/fake-model.bin")
        )
    )

    do {
        _ = try await engine.transcribe(audioURL: audioURL, languageHints: ["en"])
        Issue.record("Expected non-zero exit to throw failedToRun.")
    } catch WhisperCLITranscriptionError.failedToRun(let status, let stderr) {
        #expect(status == 42)
        #expect(stderr.contains("boom failure"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("WhisperCLITranscriptionEngine throws outputMissing when txt is absent")
func whisperCLITranscriptionEngineMissingOutput() async throws {
    let scriptURL = try makeExecutableScript(
        """
        #!/bin/sh
        exit 0
        """
    )
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let engine = WhisperCLITranscriptionEngine(
        config: .init(
            whisperCLIPath: scriptURL,
            modelPath: URL(fileURLWithPath: "/tmp/fake-model.bin")
        )
    )

    do {
        _ = try await engine.transcribe(audioURL: audioURL, languageHints: ["en"])
        Issue.record("Expected missing output to throw outputMissing.")
    } catch WhisperCLITranscriptionError.outputMissing {
        // Expected.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("WhisperCLITranscriptionEngine cancellation escalates when child ignores SIGTERM")
func whisperCLITranscriptionEngineCancellationEscalation() async throws {
    let scriptURL = try makeExecutableScript(
        """
        #!/bin/sh
        trap '' TERM
        while :; do
          sleep 1
        done
        """
    )
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let engine = WhisperCLITranscriptionEngine(
        config: .init(
            whisperCLIPath: scriptURL,
            modelPath: URL(fileURLWithPath: "/tmp/fake-model.bin")
        )
    )

    let task = Task {
        try await engine.transcribe(audioURL: audioURL, languageHints: ["en"])
    }

    try await Task.sleep(nanoseconds: 120_000_000)
    task.cancel()
    let cancellationStart = Date()

    do {
        _ = try await awaitTaskValue(task, timeoutNanoseconds: 6_000_000_000)
        Issue.record("Expected cancellation to throw.")
    } catch is CancellationError {
        let elapsed = Date().timeIntervalSince(cancellationStart)
        #expect(elapsed < 6.0)
    } catch is TaskValueTimeoutError {
        Issue.record("Cancellation did not complete within timeout.")
    } catch {
        Issue.record("Expected CancellationError, got: \(error)")
    }
}

private struct TaskValueTimeoutError: Error {}

private func awaitTaskValue<T>(
    _ task: Task<T, Error>,
    timeoutNanoseconds: UInt64
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await task.value
        }
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            task.cancel()
            throw TaskValueTimeoutError()
        }
        guard let value = try await group.next() else {
            throw TaskValueTimeoutError()
        }
        group.cancelAll()
        return value
    }
}

private func makeExecutableScript(_ body: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fake-whisper-\(UUID().uuidString).sh")
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: url.path)
    return url
}
