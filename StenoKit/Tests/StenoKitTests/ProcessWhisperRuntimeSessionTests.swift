#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import StenoKit

@Test("Broken helper input throws instead of terminating the host process")
func brokenWhisperHelperInputSuppressesSIGPIPE() throws {
    let pipe = Pipe()
    let writer = pipe.fileHandleForWriting
    defer { try? writer.close() }

    try WhisperPipeSafety.suppressSIGPIPE(on: writer.fileDescriptor)
    #expect(fcntl(writer.fileDescriptor, F_GETNOSIGPIPE) == 1)
    try pipe.fileHandleForReading.close()

    do {
        try writer.write(contentsOf: Data([0]))
        Issue.record("Writing to a closed helper pipe unexpectedly succeeded")
    } catch {
        // Reaching this catch proves the broken pipe was reported without terminating Steno.
    }
}

@Test("A helper exit after accepting transcription falls back exactly once")
func exitedWhisperHelperFallsBackExactlyOnce() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-exited-helper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let helperURL = directory.appendingPathComponent("fake-runtime")
    let modelURL = directory.appendingPathComponent("model.bin")
    let pidURL = directory.appendingPathComponent("helper.pid")
    try Data([0]).write(to: modelURL)
    try fakeExitedHelperSource.write(to: helperURL, atomically: true, encoding: .utf8)
    #expect(chmod(helperURL.path, S_IRWXU) == 0)

    var environment = ProcessInfo.processInfo.environment
    environment["STENO_TEST_HELPER_PID_FILE"] = pidURL.path
    let fallbackState = ProcessFallbackState()
    let engine = RetainedWhisperTranscriptionEngine(
        configuration: RetainedWhisperTranscriptionConfiguration(
            helperExecutableURL: helperURL,
            modelPath: modelURL,
            threadCount: 1,
            vadModelPath: nil,
            suppressNonSpeechTokens: true,
            suppressRegex: nil,
            environment: environment
        ),
        fallback: ProcessFallbackEngine(state: fallbackState)
    )

    let result = try await engine.transcribe(
        audioURL: directory.appendingPathComponent("unused.wav"),
        request: .init()
    )
    await engine.shutdown()

    #expect(result.text == "fallback")
    #expect(await fallbackState.count == 1)
    let pid = try #require(Int32(
        String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    ))
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
}

@Test("A helper stalled during model load is terminated and falls back exactly once")
func stalledWhisperHelperLoadFallsBackExactlyOnce() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-stalled-load-helper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let helperURL = directory.appendingPathComponent("fake-runtime")
    let modelURL = directory.appendingPathComponent("model.bin")
    let pidURL = directory.appendingPathComponent("helper.pid")
    try Data([0]).write(to: modelURL)
    try fakeLoadStalledHelperSource.write(to: helperURL, atomically: true, encoding: .utf8)
    #expect(chmod(helperURL.path, S_IRWXU) == 0)

    var environment = ProcessInfo.processInfo.environment
    environment["STENO_TEST_HELPER_PID_FILE"] = pidURL.path
    let fallbackState = ProcessFallbackState()
    let engine = RetainedWhisperTranscriptionEngine(
        configuration: RetainedWhisperTranscriptionConfiguration(
            helperExecutableURL: helperURL,
            modelPath: modelURL,
            threadCount: 1,
            vadModelPath: nil,
            suppressNonSpeechTokens: true,
            suppressRegex: nil,
            modelLoadTimeout: .milliseconds(500),
            inferenceTimeout: .seconds(1),
            environment: environment
        ),
        fallback: ProcessFallbackEngine(state: fallbackState)
    )

    let clock = ContinuousClock()
    let started = clock.now
    let result = try await engine.transcribe(
        audioURL: directory.appendingPathComponent("unused.wav"),
        request: .init()
    )
    await engine.shutdown()

    #expect(started.duration(to: clock.now) < .seconds(2))
    #expect(result.text == "fallback")
    #expect(await fallbackState.count == 1)
}

@Test("A helper stalled during inference is terminated and falls back exactly once")
func stalledWhisperHelperInferenceFallsBackExactlyOnce() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-stalled-inference-helper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let helperURL = directory.appendingPathComponent("fake-runtime")
    let modelURL = directory.appendingPathComponent("model.bin")
    let pidURL = directory.appendingPathComponent("helper.pid")
    try Data([0]).write(to: modelURL)
    try fakeWedgedHelperSource.write(to: helperURL, atomically: true, encoding: .utf8)
    #expect(chmod(helperURL.path, S_IRWXU) == 0)

    var environment = ProcessInfo.processInfo.environment
    environment["STENO_TEST_HELPER_PID_FILE"] = pidURL.path
    let fallbackState = ProcessFallbackState()
    let engine = RetainedWhisperTranscriptionEngine(
        configuration: RetainedWhisperTranscriptionConfiguration(
            helperExecutableURL: helperURL,
            modelPath: modelURL,
            threadCount: 1,
            vadModelPath: nil,
            suppressNonSpeechTokens: true,
            suppressRegex: nil,
            modelLoadTimeout: .seconds(5),
            inferenceTimeout: .milliseconds(500),
            environment: environment
        ),
        fallback: ProcessFallbackEngine(state: fallbackState)
    )

    let clock = ContinuousClock()
    let started = clock.now
    let result = try await engine.transcribe(
        audioURL: directory.appendingPathComponent("unused.wav"),
        request: .init()
    )
    await engine.shutdown()

    #expect(started.duration(to: clock.now) < .seconds(7))
    #expect(result.text == "fallback")
    #expect(await fallbackState.count == 1)
}

@Test("Inference watchdog expands for long WAV captures")
func whisperRuntimeInferenceWatchdogIsDurationAware() throws {
    let audioURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-long-capture-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: audioURL) }

    try writeSparsePCMRecording(durationSeconds: 600, to: audioURL)

    let timeout = WhisperRuntimeWatchdog.inferenceTimeout(
        minimum: .seconds(180),
        audioURL: audioURL
    )
    #expect(timeout == .seconds(1_260))
}

@Test("Inference watchdog rejects malformed PCM timing metadata")
func whisperRuntimeInferenceWatchdogRejectsMalformedPCMMetadata() throws {
    let audioURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-malformed-capture-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: audioURL) }

    try writeSparsePCMRecording(durationSeconds: 600, byteRate: 1, to: audioURL)

    #expect(
        WhisperRuntimeWatchdog.inferenceTimeout(
            minimum: .seconds(180),
            audioURL: audioURL
        ) == .seconds(180)
    )
}

@Test("Inference watchdog rejects non-PCM WAV captures")
func whisperRuntimeInferenceWatchdogRejectsNonPCM() throws {
    let audioURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-non-pcm-capture-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: audioURL) }

    try writeSparsePCMRecording(durationSeconds: 600, formatTag: 3, to: audioURL)

    #expect(
        WhisperRuntimeWatchdog.inferenceTimeout(
            minimum: .seconds(180),
            audioURL: audioURL
        ) == .seconds(180)
    )
}

@Test("Inference watchdog rejects declared captures beyond the supported duration")
func whisperRuntimeInferenceWatchdogRejectsOverlongCapture() throws {
    let audioURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-overlong-capture-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: audioURL) }

    try writeSparsePCMRecording(durationSeconds: 21_601, to: audioURL)

    #expect(
        WhisperRuntimeWatchdog.inferenceTimeout(
            minimum: .seconds(180),
            audioURL: audioURL
        ) == .seconds(180)
    )
}

@Test("Inference watchdog rejects truncated WAV captures")
func whisperRuntimeInferenceWatchdogRejectsTruncatedCapture() throws {
    let audioURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-truncated-capture-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: audioURL) }

    try writeSparsePCMRecording(durationSeconds: 600, to: audioURL)
    let handle = try FileHandle(forWritingTo: audioURL)
    try handle.truncate(atOffset: 44)
    try handle.close()

    #expect(
        WhisperRuntimeWatchdog.inferenceTimeout(
            minimum: .seconds(180),
            audioURL: audioURL
        ) == .seconds(180)
    )
}

@Test("A wedged helper cannot block retained-runtime shutdown")
func wedgedWhisperHelperShutdownIsBoundedAndReaped() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-wedged-helper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let helperURL = directory.appendingPathComponent("fake-runtime")
    let modelURL = directory.appendingPathComponent("model.bin")
    let pidURL = directory.appendingPathComponent("helper.pid")
    try Data([0]).write(to: modelURL)
    try fakeWedgedHelperSource.write(to: helperURL, atomically: true, encoding: .utf8)
    #expect(chmod(helperURL.path, S_IRWXU) == 0)

    var environment = ProcessInfo.processInfo.environment
    environment["STENO_TEST_HELPER_PID_FILE"] = pidURL.path
    let factory = ProcessWhisperRuntimeSessionFactory()
    let session = try await factory.makeSession(
        configuration: RetainedWhisperTranscriptionConfiguration(
            helperExecutableURL: helperURL,
            modelPath: modelURL,
            threadCount: 1,
            vadModelPath: nil,
            suppressNonSpeechTokens: true,
            suppressRegex: nil,
            environment: environment
        )
    )

    let pid = try #require(Int32(
        String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    ))
    let clock = ContinuousClock()
    let started = clock.now
    await session.shutdown()

    #expect(started.duration(to: clock.now) < .seconds(2))
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
}

@Test("A graceful helper exits after cleanup without receiving SIGTERM")
func gracefulWhisperHelperShutdownWaitsForNaturalExit() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-graceful-helper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let helperURL = directory.appendingPathComponent("fake-runtime")
    let modelURL = directory.appendingPathComponent("model.bin")
    let pidURL = directory.appendingPathComponent("helper.pid")
    let cleanupURL = directory.appendingPathComponent("cleanup.complete")
    let terminationURL = directory.appendingPathComponent("sigterm.received")
    try Data([0]).write(to: modelURL)
    try fakeGracefulHelperSource.write(to: helperURL, atomically: true, encoding: .utf8)
    #expect(chmod(helperURL.path, S_IRWXU) == 0)

    var environment = ProcessInfo.processInfo.environment
    environment["STENO_TEST_HELPER_PID_FILE"] = pidURL.path
    environment["STENO_TEST_HELPER_CLEANUP_FILE"] = cleanupURL.path
    environment["STENO_TEST_HELPER_SIGTERM_FILE"] = terminationURL.path
    let session = try await ProcessWhisperRuntimeSessionFactory().makeSession(
        configuration: RetainedWhisperTranscriptionConfiguration(
            helperExecutableURL: helperURL,
            modelPath: modelURL,
            threadCount: 1,
            vadModelPath: nil,
            suppressNonSpeechTokens: true,
            suppressRegex: nil,
            environment: environment
        )
    )
    let pid = try #require(Int32(
        String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    ))

    await session.shutdown()

    #expect(FileManager.default.fileExists(atPath: cleanupURL.path))
    #expect(!FileManager.default.fileExists(atPath: terminationURL.path))
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
}

private actor ProcessFallbackState {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private struct ProcessFallbackEngine: TranscriptionEngine {
    let state: ProcessFallbackState

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        _ = audioURL
        _ = request
        await state.record()
        return RawTranscript(text: "fallback")
    }
}

private func writeSparsePCMRecording(
    durationSeconds: UInt32,
    formatTag: UInt16 = 1,
    byteRate: UInt32 = 32_000,
    to url: URL
) throws {
    let dataByteCount = byteRate * durationSeconds
    var header = Data()
    header.append(contentsOf: Data("RIFF".utf8))
    header.appendLittleEndian(UInt32(36) + dataByteCount)
    header.append(contentsOf: Data("WAVEfmt ".utf8))
    header.appendLittleEndian(UInt32(16))
    header.appendLittleEndian(formatTag)
    header.appendLittleEndian(UInt16(1))
    header.appendLittleEndian(UInt32(16_000))
    header.appendLittleEndian(byteRate)
    header.appendLittleEndian(UInt16(2))
    header.appendLittleEndian(UInt16(16))
    header.append(contentsOf: Data("data".utf8))
    header.appendLittleEndian(dataByteCount)
    try header.write(to: url)

    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(header.count) + UInt64(dataByteCount))
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}

private let fakeExitedHelperSource = #"""
#!/usr/bin/env python3
import os
import struct
import sys

with open(os.environ["STENO_TEST_HELPER_PID_FILE"], "w", encoding="utf-8") as handle:
    handle.write(str(os.getpid()))

def read_exact(count):
    data = b""
    while len(data) < count:
        chunk = sys.stdin.buffer.read(count - len(data))
        if not chunk:
            raise SystemExit(1)
        data += chunk
    return data

def read_frame():
    header = read_exact(36)
    values = struct.unpack(">IHH16sQI", header)
    read_exact(values[-1])
    return values

magic, version, _, request_id, generation, _ = read_frame()
sys.stdout.buffer.write(struct.pack(">IHH16sQI", magic, version, 2, request_id, generation, 0))
sys.stdout.buffer.flush()

read_frame()
raise SystemExit(17)
"""#

private let fakeWedgedHelperSource = #"""
#!/usr/bin/env python3
import os
import signal
import struct
import sys
import time

signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(os.environ["STENO_TEST_HELPER_PID_FILE"], "w", encoding="utf-8") as handle:
    handle.write(str(os.getpid()))

def read_exact(count):
    data = b""
    while len(data) < count:
        chunk = sys.stdin.buffer.read(count - len(data))
        if not chunk:
            raise SystemExit(1)
        data += chunk
    return data

header = read_exact(36)
magic, version, operation, request_id, generation, payload_size = struct.unpack(">IHH16sQI", header)
read_exact(payload_size)
ready = struct.pack(">IHH16sQI", magic, version, 2, request_id, generation, 0)
sys.stdout.buffer.write(ready)
sys.stdout.buffer.flush()

header = read_exact(36)
_, _, _, _, _, payload_size = struct.unpack(">IHH16sQI", header)
read_exact(payload_size)
while True:
    time.sleep(60)
"""#

private let fakeLoadStalledHelperSource = #"""
#!/usr/bin/env python3
import os
import signal
import struct
import sys
import time

signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(os.environ["STENO_TEST_HELPER_PID_FILE"], "w", encoding="utf-8") as handle:
    handle.write(str(os.getpid()))

header = sys.stdin.buffer.read(36)
if len(header) != 36:
    raise SystemExit(1)
payload_size = struct.unpack(">IHH16sQI", header)[-1]
if len(sys.stdin.buffer.read(payload_size)) != payload_size:
    raise SystemExit(1)
while True:
    time.sleep(60)
"""#

private let fakeGracefulHelperSource = #"""
#!/usr/bin/env python3
import os
import signal
import struct
import sys
import time

def received_sigterm(_signal, _frame):
    with open(os.environ["STENO_TEST_HELPER_SIGTERM_FILE"], "w", encoding="utf-8") as handle:
        handle.write("received")
    raise SystemExit(143)

signal.signal(signal.SIGTERM, received_sigterm)
with open(os.environ["STENO_TEST_HELPER_PID_FILE"], "w", encoding="utf-8") as handle:
    handle.write(str(os.getpid()))

def read_exact(count):
    data = b""
    while len(data) < count:
        chunk = sys.stdin.buffer.read(count - len(data))
        if not chunk:
            raise SystemExit(1)
        data += chunk
    return data

def read_frame():
    header = read_exact(36)
    values = struct.unpack(">IHH16sQI", header)
    read_exact(values[-1])
    return values

magic, version, _, request_id, generation, _ = read_frame()
sys.stdout.buffer.write(struct.pack(">IHH16sQI", magic, version, 2, request_id, generation, 0))
sys.stdout.buffer.flush()

magic, version, _, request_id, generation, _ = read_frame()
with open(os.environ["STENO_TEST_HELPER_CLEANUP_FILE"], "w", encoding="utf-8") as handle:
    handle.write("complete")
sys.stdout.buffer.write(struct.pack(">IHH16sQI", magic, version, 7, request_id, generation, 0))
sys.stdout.buffer.flush()
time.sleep(0.1)
"""#
#endif
