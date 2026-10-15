import Foundation
import Testing
@testable import StenoKit

private func deadlineScratchURL(_ name: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("steno-deadline-\(UUID().uuidString)-\(name)")
}

private func recordedPID(at url: URL) -> pid_t? {
    for _ in 0..<200 {
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return pid
        }
        usleep(10_000)
    }
    return nil
}

private func processIsAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

/// A shell loop that runs for about two minutes on an idle machine, then writes
/// `natural` to `markerURL`. The marker is the evidence that the child ended on its
/// own; a run the deadline ended never writes it, however slow the machine is.
private func longLoop(writingTo markerURL: URL) -> String {
    "i=0; while [ $i -lt 600 ]; do sleep 0.2; i=$((i + 1)); done; echo natural > '\(markerURL.path)'"
}

@Test("ProcessRunner terminates a child that outlives its deadline")
func processRunnerTerminatesChildAtDeadline() async throws {
    let pidURL = deadlineScratchURL("pid")
    let markerURL = deadlineScratchURL("natural-exit")
    defer { for url in [pidURL, markerURL] { try? FileManager.default.removeItem(at: url) } }

    await #expect(throws: ProcessRunnerError.timedOut(after: .seconds(1))) {
        _ = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo $$ > '\(pidURL.path)'; \(longLoop(writingTo: markerURL))"],
            timeout: .seconds(1)
        )
    }

    #expect(!FileManager.default.fileExists(atPath: markerURL.path), "the child ran to its natural end")
    let pid = try #require(recordedPID(at: pidURL))
    #expect(!processIsAlive(pid))
}

@Test("ProcessRunner forcibly kills a child that ignores termination after its deadline")
func processRunnerKillsChildIgnoringTerminationAtDeadline() async throws {
    let pidURL = deadlineScratchURL("pid")
    let markerURL = deadlineScratchURL("natural-exit")
    defer { for url in [pidURL, markerURL] { try? FileManager.default.removeItem(at: url) } }

    await #expect(throws: ProcessRunnerError.timedOut(after: .seconds(1))) {
        _ = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; echo $$ > '\(pidURL.path)'; \(longLoop(writingTo: markerURL))"],
            timeout: .seconds(1)
        )
    }

    #expect(!FileManager.default.fileExists(atPath: markerURL.path), "the child ran to its natural end")
    let pid = try #require(recordedPID(at: pidURL))
    #expect(!processIsAlive(pid))
}

@Test("ProcessRunner returns normally when the child exits before its deadline")
func processRunnerReturnsBeforeDeadline() async throws {
    let result = try await ProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf done; exit 3"],
        timeout: .seconds(10)
    )
    #expect(result.terminationStatus == 3)
    #expect(result.standardOutput == Data("done".utf8))
}

@Test("The whisper-cli fallback stops a run that never finishes and reports it")
func whisperCLIFallbackStopsAtDeadline() async throws {
    let scriptURL = deadlineScratchURL("whisper-cli.sh")
    try """
    #!/bin/sh
    i=0; while [ $i -lt 150 ]; do sleep 0.2; i=$((i + 1)); done
    """.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    let audioURL = deadlineScratchURL("audio.wav")
    try Data().write(to: audioURL)
    defer {
        for url in [scriptURL, audioURL] { try? FileManager.default.removeItem(at: url) }
    }

    let engine = WhisperCLITranscriptionEngine(config: .init(
        whisperCLIPath: scriptURL,
        modelPath: URL(fileURLWithPath: "/tmp/steno-model.bin"),
        minimumTimeout: .seconds(1)
    ))

    await #expect(throws: WhisperCLITranscriptionError.timedOut) {
        _ = try await engine.transcribe(audioURL: audioURL, languageHints: ["en"])
    }
    #expect(try runningProcessCount(matching: scriptURL.path) == 0)
}

/// Counts live processes whose command line contains `marker`.
private func runningProcessCount(matching marker: String) throws -> Int {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", marker]
    let output = Pipe()
    pgrep.standardOutput = output
    try pgrep.run()
    pgrep.waitUntilExit()
    let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return text.split(whereSeparator: \.isNewline).count
}

@Test("The whisper-cli deadline grows with the recording like the helper's watchdog")
func whisperCLIDeadlineScalesWithAudio() throws {
    let seconds = 10
    var pcm = Data(count: seconds * 32_000)
    pcm[0] = 1
    var wav = Data("RIFF".utf8)
    func append<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
    }
    append(UInt32(36 + pcm.count))
    wav.append(Data("WAVEfmt ".utf8))
    append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(UInt32(16_000)); append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
    wav.append(Data("data".utf8))
    append(UInt32(pcm.count))
    wav.append(pcm)
    let audioURL = deadlineScratchURL("ten-seconds.wav")
    try wav.write(to: audioURL)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let short = WhisperCLITranscriptionEngine.Configuration(
        whisperCLIPath: URL(fileURLWithPath: "/tmp/whisper-cli"),
        modelPath: URL(fileURLWithPath: "/tmp/model.bin"),
        minimumTimeout: .seconds(1)
    )
    // Twice the audio plus a minute, as for the retained helper.
    #expect(short.timeout(for: audioURL) == .seconds(80))

    let standard = WhisperCLITranscriptionEngine.Configuration(
        whisperCLIPath: URL(fileURLWithPath: "/tmp/whisper-cli"),
        modelPath: URL(fileURLWithPath: "/tmp/model.bin")
    )
    #expect(standard.timeout(for: audioURL) == standard.minimumTimeout)
    #expect(standard.minimumTimeout >= .seconds(300))
}
