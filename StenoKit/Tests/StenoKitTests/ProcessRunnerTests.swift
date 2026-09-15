import Foundation
import Testing
@testable import StenoKit

@Test("ProcessRunner final drainage includes bytes already read by an in-flight handler")
func processRunnerFinalDrainWaitsForReadAndAppend() async throws {
    let pipe = Pipe()
    let expected = Data("boom failure\n".utf8)
    try pipe.fileHandleForWriting.write(contentsOf: expected)
    try pipe.fileHandleForWriting.close()
    defer { try? pipe.fileHandleForReading.close() }
    let accumulator = PipeAccumulator()
    let captured = DispatchSemaphore(value: 0)
    let releaseRead = DispatchSemaphore(value: 0)
    let readerFinished = DispatchSemaphore(value: 0)

    let result = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            DispatchQueue.global().async {
                accumulator.appendReading {
                    let bytes = pipe.fileHandleForReading.availableData
                    captured.signal()
                    _ = releaseRead.wait(timeout: .now() + 2)
                    return bytes
                }
                readerFinished.signal()
            }
            let readStarted = captured.wait(timeout: .now() + 2) == .success
            // Hold the consumed bytes across final drainage. Only the independent
            // queue can release this fixture; no cooperative worker blocks here.
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
                releaseRead.signal()
            }
            let output = accumulator.consumeReading {
                pipe.fileHandleForReading.readDataToEndOfFile()
            }
            let completed = readerFinished.wait(timeout: .now() + 2) == .success
            continuation.resume(returning: (readStarted, completed, output))
        }
    }

    #expect(result.0)
    #expect(result.1)
    #expect(result.2 == expected)
}

@Test("ProcessRunner captures complete stdout and stderr beyond pipe capacity")
func processRunnerCapturesLargeOutputOnBothPipes() async throws {
    let result = try await ProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", """
        i=0
        while [ "$i" -lt 4096 ]; do
          printf 'stdout chunk 0123456789\n'
          printf 'stderr chunk 9876543210\n' >&2
          i=$((i + 1))
        done
        printf 'stdout tail\n'
        printf 'stderr tail\n' >&2
        exit 42
        """]
    )
    #expect(result.terminationStatus == 42)
    #expect(result.standardOutput == Data((String(repeating: "stdout chunk 0123456789\n", count: 4096) + "stdout tail\n").utf8))
    #expect(result.standardError == Data((String(repeating: "stderr chunk 9876543210\n", count: 4096) + "stderr tail\n").utf8))
}

@Test("ProcessRunner preserves caller-owned redirected handles")
func processRunnerPreservesRedirectedHandles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steno-process-redirection-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let outputURL = directory.appendingPathComponent("stdout")
    let errorURL = directory.appendingPathComponent("stderr")
    try Data().write(to: outputURL)
    try Data().write(to: errorURL)
    let output = try FileHandle(forWritingTo: outputURL)
    let error = try FileHandle(forWritingTo: errorURL)
    defer { try? output.close(); try? error.close() }
    let result = try await ProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf out; printf err >&2"],
        standardOutput: output,
        standardError: error
    )
    #expect(result.terminationStatus == 0)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.isEmpty)
    try output.write(contentsOf: Data("put".utf8))
    try error.write(contentsOf: Data("or".utf8))
    #expect(try Data(contentsOf: outputURL) == Data("output".utf8))
    #expect(try Data(contentsOf: errorURL) == Data("error".utf8))
}
