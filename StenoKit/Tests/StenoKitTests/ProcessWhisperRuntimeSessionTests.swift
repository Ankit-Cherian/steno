#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import StenoKit

@Suite(.serialized)
struct ProcessWhisperRuntimeSessionTests {
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

@Test("Stale Foundation process state cannot block shutdown forever")
func staleFoundationProcessStateHasABoundedWait() async {
    let clock = ContinuousClock()
    let started = clock.now

    await WhisperProcessExitWaiter.wait(
        timeout: .milliseconds(25),
        pollInterval: .milliseconds(1)
    ) {
        true
    }

    #expect(started.duration(to: clock.now) < .seconds(2))
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

    let result = try await engine.transcribe(
        audioURL: directory.appendingPathComponent("unused.wav"),
        request: .init()
    )
    await engine.shutdown()

    #expect(result.text == "fallback")
    #expect(await fallbackState.count == 1)
    // Under a saturated test executor the watchdog may fire before Python
    // enters user code. When the helper did publish its startup marker, prove
    // that the timed-out process was reaped; otherwise fallback is the only
    // observable contract available for a process that never initialized.
    if FileManager.default.fileExists(atPath: pidURL.path) {
        let pid = try #require(Int32(
            String(contentsOf: pidURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
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
import struct
import sys
import time

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

extension ProcessWhisperRuntimeSessionTests {
@Test("Streaming v2 handles fragmented frames, stale hypotheses, and canonical finish")
func streamingRuntimeLifecycleIsFramedAndOrdered() async throws {
    let fixture = try StreamingRuntimeFixture(helperSource: fakeStreamingLifecycleHelperSource)
    defer { fixture.remove() }
    let session = try await fixture.makeSession()
    let streamID = UUID()
    let configuration = streamingConfiguration()

    let runtimeIdentity = try await session.startStream(
        id: streamID,
        generation: 0,
        configuration: configuration
    )
    #expect(runtimeIdentity.protocolVersion == 2)
    #expect(runtimeIdentity.runtimeIdentifier.isEmpty == false)
    #expect(runtimeIdentity.modelIdentifier.count == 64)
    #expect(runtimeIdentity.vadIdentifier == nil)
    #expect(runtimeIdentity.currentASRContextCount == 1)
    #expect(runtimeIdentity.peakASRContextCount == 1)
    #expect(runtimeIdentity.runtimeIdentifier.contains("/") == false)
    #expect(runtimeIdentity.modelIdentifier.contains(fixture.modelURL.path) == false)
    let samples = Data([0x01, 0x00, 0x02, 0x00])
    try await session.append(
        try WhisperStreamAudioChunk(
            sequence: 0,
            sampleOffset: 0,
            sampleCount: 2,
            samplesS16LE: samples
        ),
        streamID: streamID,
        generation: 0
    )
    let hypothesis = try await session.requestHypothesis(
        streamID: streamID,
        generation: 0,
        revision: 1,
        watermark: 2
    )
    #expect(hypothesis == WhisperStreamHypothesis(
        revision: 1,
        watermark: 2,
        monotonicNanoseconds: 123,
        speechEvidence: .unknown,
        text: "hello"
    ))
    let final = try await session.finishStream(
        id: streamID,
        generation: 0,
        request: .init(
            canonicalAudioURL: fixture.directory.appendingPathComponent("capture.wav"),
            expectedSampleCount: 2,
            audioFNV1a64: 42,
            configuration: configuration
        )
    )
    #expect(String(data: final, encoding: .utf8) == #"{"text":"hello"}"#)
    await session.shutdown()
}

@Test("Streaming v2 finish supersedes an in-flight preview")
func streamingRuntimeFinishSupersedesPreview() async throws {
    let fixture = try StreamingRuntimeFixture(helperSource: fakeStreamingFinishRaceHelperSource)
    defer { fixture.remove() }
    let session = try await fixture.makeSession()
    let streamID = UUID()
    let configuration = streamingConfiguration()
    _ = try await session.startStream(id: streamID, generation: 0, configuration: configuration)
    try await session.append(
        try WhisperStreamAudioChunk(
            sequence: 0,
            sampleOffset: 0,
            sampleCount: 1,
            samplesS16LE: Data([0, 0])
        ),
        streamID: streamID,
        generation: 0
    )

    let preview = Task {
        try await session.requestHypothesis(
            streamID: streamID,
            generation: 0,
            revision: 1,
            watermark: 1
        )
    }
    try await fixture.waitForMarker()
    await #expect(throws: RetainedWhisperRuntimeError.staleResponse) {
        _ = try await session.requestHypothesis(
            streamID: streamID,
            generation: 0,
            revision: 2,
            watermark: 1
        )
    }
    let final = try await session.finishStream(
        id: streamID,
        generation: 0,
        request: .init(
            canonicalAudioURL: fixture.directory.appendingPathComponent("capture.wav"),
            expectedSampleCount: 1,
            audioFNV1a64: 42,
            configuration: configuration
        )
    )
    #expect(String(data: final, encoding: .utf8) == #"{"text":"final"}"#)
    await #expect(throws: RetainedWhisperRuntimeError.staleResponse) {
        _ = try await preview.value
    }
    await session.shutdown()
}

@Test("Streaming v2 cancellation retains the helper for a restart")
func streamingRuntimeCancellationAllowsRestart() async throws {
    let fixture = try StreamingRuntimeFixture(helperSource: fakeStreamingCancelRestartHelperSource)
    defer { fixture.remove() }
    let session = try await fixture.makeSession()
    let configuration = streamingConfiguration()
    let firstID = UUID()
    _ = try await session.startStream(id: firstID, generation: 0, configuration: configuration)
    await session.cancelStream(id: firstID, generation: 0)

    let secondID = UUID()
    _ = try await session.startStream(id: secondID, generation: 0, configuration: configuration)
    await session.cancelStream(id: secondID, generation: 0)
    await session.shutdown()

    let pid = try #require(Int32(
        String(contentsOf: fixture.pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    ))
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
}

@Test("Streaming v2 cancellation promptly supersedes finish and retains the helper")
func streamingRuntimeCancellationSupersedesFinishAndAllowsRestart() async throws {
    let fixture = try StreamingRuntimeFixture(helperSource: fakeStreamingCancelDuringFinishHelperSource)
    defer { fixture.remove() }
    let session = try await fixture.makeSession()
    let configuration = streamingConfiguration()
    let firstID = UUID()
    _ = try await session.startStream(id: firstID, generation: 0, configuration: configuration)
    let finish = Task {
        try await session.finishStream(
            id: firstID,
            generation: 0,
            request: .init(
                canonicalAudioURL: fixture.directory.appendingPathComponent("capture.wav"),
                expectedSampleCount: 0,
                audioFNV1a64: 14_695_981_039_346_656_037,
                configuration: configuration
            )
        )
    }
    try await fixture.waitForMarker(contents: "finish-received")
    await session.cancelStream(id: firstID, generation: 0)
    await #expect(throws: RetainedWhisperRuntimeError.staleResponse) {
        _ = try await finish.value
    }

    let secondID = UUID()
    _ = try await session.startStream(id: secondID, generation: 1, configuration: configuration)
    await session.cancelStream(id: secondID, generation: 1)
    await session.shutdown()
}

@Test("Streaming v2 finish safely supersedes an append acknowledgement in flight")
func streamingRuntimeFinishDuringAppendAcknowledgement() async throws {
    let fixture = try StreamingRuntimeFixture(helperSource: fakeStreamingAppendFinishRaceHelperSource)
    defer { fixture.remove() }
    let session = try await fixture.makeSession()
    let streamID = UUID()
    let configuration = streamingConfiguration()
    _ = try await session.startStream(id: streamID, generation: 0, configuration: configuration)

    let append = Task.detached(priority: .background) {
        try await session.append(
            try WhisperStreamAudioChunk(
                sequence: 0,
                sampleOffset: 0,
                sampleCount: 2,
                samplesS16LE: Data([1, 0, 2, 0])
            ),
            streamID: streamID,
            generation: 0
        )
    }
    try await fixture.waitForMarker()

    let final = try await session.finishStream(
        id: streamID,
        generation: 0,
        request: .init(
            canonicalAudioURL: fixture.directory.appendingPathComponent("capture.wav"),
            expectedSampleCount: 2,
            audioFNV1a64: 42,
            configuration: configuration
        )
    )
    try await append.value
    #expect(String(data: final, encoding: .utf8) == #"{"text":"final-after-append"}"#)
    await session.shutdown()
}

@Test("Streaming v2 appends audio while one hypothesis is in flight")
func streamingRuntimeAppendDuringHypothesis() async throws {
    let fixture = try StreamingRuntimeFixture(helperSource: fakeStreamingAppendDuringHypothesisHelperSource)
    defer { fixture.remove() }
    let session = try await fixture.makeSession(vadModelURL: fixture.vadModelURL)
    let streamID = UUID()
    let configuration = streamingConfiguration(vadModelPath: fixture.vadModelURL)
    _ = try await session.startStream(id: streamID, generation: 0, configuration: configuration)
    try await session.append(
        try WhisperStreamAudioChunk(
            sequence: 0,
            sampleOffset: 0,
            sampleCount: 1,
            samplesS16LE: Data([1, 0])
        ),
        streamID: streamID,
        generation: 0
    )

    let preview = Task {
        try await session.requestHypothesis(
            streamID: streamID,
            generation: 0,
            revision: 1,
            watermark: 1
        )
    }
    try await fixture.waitForMarker(contents: "decode-received")
    let append = Task {
        try await session.append(
            try WhisperStreamAudioChunk(
                sequence: 1,
                sampleOffset: 1,
                sampleCount: 1,
                samplesS16LE: Data([2, 0])
            ),
            streamID: streamID,
            generation: 0
        )
    }
    try await fixture.waitForMarker(contents: "append-received")

    let hypothesis = try await preview.value
    try await append.value
    #expect(hypothesis.revision == 1)
    #expect(hypothesis.watermark == 1)
    #expect(hypothesis.speechEvidence == .speechDetected)
    #expect(hypothesis.text == "first-window")

    let final = try await session.finishStream(
        id: streamID,
        generation: 0,
        request: .init(
            canonicalAudioURL: fixture.directory.appendingPathComponent("capture.wav"),
            expectedSampleCount: 2,
            audioFNV1a64: 42,
            configuration: configuration
        )
    )
    #expect(String(data: final, encoding: .utf8) == #"{"text":"complete"}"#)
    await session.shutdown()
}

@Test("Streaming v2 finish supersedes a preview and tail append together")
func streamingRuntimeFinishDuringHypothesisAndAppend() async throws {
    let fixture = try StreamingRuntimeFixture(helperSource: fakeStreamingFinishDuringHypothesisAndAppendHelperSource)
    defer { fixture.remove() }
    let session = try await fixture.makeSession()
    let streamID = UUID()
    let configuration = streamingConfiguration()
    _ = try await session.startStream(id: streamID, generation: 0, configuration: configuration)
    try await session.append(
        try WhisperStreamAudioChunk(
            sequence: 0,
            sampleOffset: 0,
            sampleCount: 1,
            samplesS16LE: Data([1, 0])
        ),
        streamID: streamID,
        generation: 0
    )

    let preview = Task {
        try await session.requestHypothesis(
            streamID: streamID,
            generation: 0,
            revision: 1,
            watermark: 1
        )
    }
    try await fixture.waitForMarker(contents: "decode-received")
    let append = Task {
        try await session.append(
            try WhisperStreamAudioChunk(
                sequence: 1,
                sampleOffset: 1,
                sampleCount: 1,
                samplesS16LE: Data([2, 0])
            ),
            streamID: streamID,
            generation: 0
        )
    }
    try await fixture.waitForMarker(contents: "append-received")

    let final = try await session.finishStream(
        id: streamID,
        generation: 0,
        request: .init(
            canonicalAudioURL: fixture.directory.appendingPathComponent("capture.wav"),
            expectedSampleCount: 2,
            audioFNV1a64: 42,
            configuration: configuration
        )
    )
    try await append.value
    await #expect(throws: RetainedWhisperRuntimeError.staleResponse) {
        _ = try await preview.value
    }
    #expect(String(data: final, encoding: .utf8) == #"{"text":"tail-complete"}"#)
    await session.shutdown()
}

@Test("Streaming v2 preview errors do not fail an overlapping append")
func streamingRuntimeCorrelatesPreviewErrorDuringAppend() async throws {
    let fixture = try StreamingRuntimeFixture(helperSource: fakeStreamingCorrelatedPreviewErrorHelperSource)
    defer { fixture.remove() }
    let session = try await fixture.makeSession()
    let streamID = UUID()
    let configuration = streamingConfiguration()
    _ = try await session.startStream(id: streamID, generation: 0, configuration: configuration)
    try await session.append(
        try WhisperStreamAudioChunk(
            sequence: 0,
            sampleOffset: 0,
            sampleCount: 1,
            samplesS16LE: Data([1, 0])
        ),
        streamID: streamID,
        generation: 0
    )

    let preview = Task {
        try await session.requestHypothesis(
            streamID: streamID,
            generation: 0,
            revision: 1,
            watermark: 1
        )
    }
    try await fixture.waitForMarker(contents: "decode-received")
    let append = Task {
        try await session.append(
            try WhisperStreamAudioChunk(
                sequence: 1,
                sampleOffset: 1,
                sampleCount: 1,
                samplesS16LE: Data([2, 0])
            ),
            streamID: streamID,
            generation: 0
        )
    }

    await #expect(throws: RetainedWhisperRuntimeError.invalidResponse) {
        _ = try await preview.value
    }
    try await append.value
    let final = try await session.finishStream(
        id: streamID,
        generation: 0,
        request: .init(
            canonicalAudioURL: fixture.directory.appendingPathComponent("capture.wav"),
            expectedSampleCount: 2,
            audioFNV1a64: 42,
            configuration: configuration
        )
    )
    #expect(String(data: final, encoding: .utf8) == #"{"text":"correlated-final"}"#)
    await session.shutdown()
}

@Test("Streaming v2 append errors do not fail an overlapping hypothesis")
func streamingRuntimeCorrelatesAppendErrorDuringPreview() async throws {
    let fixture = try StreamingRuntimeFixture(helperSource: fakeStreamingCorrelatedAppendErrorHelperSource)
    defer { fixture.remove() }
    let session = try await fixture.makeSession(vadModelURL: fixture.vadModelURL)
    let streamID = UUID()
    let configuration = streamingConfiguration(vadModelPath: fixture.vadModelURL)
    _ = try await session.startStream(
        id: streamID,
        generation: 0,
        configuration: configuration
    )
    try await session.append(
        try WhisperStreamAudioChunk(
            sequence: 0,
            sampleOffset: 0,
            sampleCount: 1,
            samplesS16LE: Data([1, 0])
        ),
        streamID: streamID,
        generation: 0
    )

    let preview = Task {
        try await session.requestHypothesis(
            streamID: streamID,
            generation: 0,
            revision: 1,
            watermark: 1
        )
    }
    try await fixture.waitForMarker(contents: "decode-received")
    let append = Task {
        try await session.append(
            try WhisperStreamAudioChunk(
                sequence: 1,
                sampleOffset: 1,
                sampleCount: 1,
                samplesS16LE: Data([2, 0])
            ),
            streamID: streamID,
            generation: 0
        )
    }

    await #expect(throws: RetainedWhisperRuntimeError.invalidResponse) {
        try await append.value
    }
    let hypothesis = try await preview.value
    #expect(hypothesis.text == "still-valid")
    #expect(hypothesis.speechEvidence == .noSpeechDetected)
    await session.cancelStream(id: streamID, generation: 0)
    await session.shutdown()
}

@Test("Streaming v2 rejects an unknown preview speech evidence value")
func streamingRuntimeRejectsUnknownSpeechEvidenceWireValue() async throws {
    let fixture = try StreamingRuntimeFixture(helperSource: fakeStreamingInvalidSpeechEvidenceHelperSource)
    defer { fixture.remove() }
    let session = try await fixture.makeSession()
    let streamID = UUID()
    _ = try await session.startStream(
        id: streamID,
        generation: 0,
        configuration: streamingConfiguration()
    )
    await #expect(throws: RetainedWhisperRuntimeError.invalidResponse) {
        _ = try await session.requestHypothesis(
            streamID: streamID,
            generation: 0,
            revision: 1,
            watermark: 0
        )
    }
    await session.shutdown()
}

@Test("Streaming v2 rejects oversized helper payloads and unexpected death")
func streamingRuntimeRejectsProtocolFailure() async throws {
    for helperSource in [fakeStreamingOversizedHelperSource, fakeStreamingExitedHelperSource] {
        let fixture = try StreamingRuntimeFixture(helperSource: helperSource)
        let session = try await fixture.makeSession()
        let streamID = UUID()
        _ = try await session.startStream(
            id: streamID,
            generation: 0,
            configuration: streamingConfiguration()
        )
        await #expect(throws: (any Error).self) {
            _ = try await session.requestHypothesis(
                streamID: streamID,
                generation: 0,
                revision: 1,
                watermark: 0
            )
        }
        await session.shutdown()
        fixture.remove()
    }
}

@Test("Streaming v2 rejects mismatched identity and ASR context telemetry")
func streamingRuntimeRejectsIdentityMismatch() async throws {
    let missingCorrelationCapability = fakeStreamingProtocolPrelude.replacingOccurrences(
        of: "struct.pack(\">II\", 2, 0x7f)",
        with: "struct.pack(\">II\", 2, 0x3f)"
    )
    let capabilityFixture = try StreamingRuntimeFixture(helperSource: missingCorrelationCapability)
    await #expect(throws: RetainedWhisperRuntimeError.invalidResponse) {
        _ = try await capabilityFixture.makeSession()
    }
    capabilityFixture.remove()

    let mismatchedReady = fakeStreamingProtocolPrelude.replacingOccurrences(
        of: "write_frame(load, 2, fragmented=True)",
        with: "identity_payload = struct.pack('>II', 2, 0x7f) + pack_string(b'wrong-runtime') + pack_string(model_identity) + pack_string(vad_identity) + struct.pack('>II', 1, 1)\nwrite_frame(load, 2, fragmented=True)"
    )
    let readyFixture = try StreamingRuntimeFixture(helperSource: mismatchedReady)
    await #expect(throws: RetainedWhisperRuntimeError.staleResponse) {
        _ = try await readyFixture.makeSession()
    }
    readyFixture.remove()

    let startFixture = try StreamingRuntimeFixture(
        helperSource: fakeStreamingProtocolPrelude + "\n" + #"""
start = read_frame()
identity_payload = struct.pack(">II", 2, 0x7f) + pack_string(b"wrong-runtime") + pack_string(model_identity) + pack_string(vad_identity) + struct.pack(">II", 1, 1)
write_frame(start, 10)
"""#
    )
    let session = try await startFixture.makeSession()
    await #expect(throws: RetainedWhisperRuntimeError.staleResponse) {
        _ = try await session.startStream(
            id: UUID(),
            generation: 0,
            configuration: streamingConfiguration()
        )
    }
    await session.shutdown()
    startFixture.remove()

    let missingTelemetry = fakeStreamingProtocolPrelude.replacingOccurrences(
        of: "    + struct.pack(\">II\", 1, 1)\n",
        with: ""
    )
    let missingTelemetryFixture = try StreamingRuntimeFixture(helperSource: missingTelemetry)
    await #expect(throws: RetainedWhisperRuntimeError.invalidResponse) {
        _ = try await missingTelemetryFixture.makeSession()
    }
    missingTelemetryFixture.remove()

    let duplicateReadyContext = fakeStreamingProtocolPrelude.replacingOccurrences(
        of: "struct.pack(\">II\", 1, 1)",
        with: "struct.pack(\">II\", 1, 2)"
    )
    let duplicateReadyFixture = try StreamingRuntimeFixture(helperSource: duplicateReadyContext)
    await #expect(throws: RetainedWhisperRuntimeError.staleResponse) {
        _ = try await duplicateReadyFixture.makeSession()
    }
    duplicateReadyFixture.remove()

    let stalePeakFixture = try StreamingRuntimeFixture(
        helperSource: fakeStreamingProtocolPrelude + "\n" + #"""
start = read_frame()
identity_payload = struct.pack(">II", 2, 0x7f) + pack_string(runtime_identity) + pack_string(model_identity) + pack_string(vad_identity) + struct.pack(">II", 1, 2)
write_frame(start, 10)
"""#
    )
    let stalePeakSession = try await stalePeakFixture.makeSession()
    await #expect(throws: RetainedWhisperRuntimeError.staleResponse) {
        _ = try await stalePeakSession.startStream(
            id: UUID(),
            generation: 0,
            configuration: streamingConfiguration()
        )
    }
    await stalePeakSession.shutdown()
    stalePeakFixture.remove()
}

@Test("Streaming v2 binds the configured VAD identity without exposing its path")
func streamingRuntimeAcknowledgesConfiguredVADIdentity() async throws {
    let source = fakeStreamingProtocolPrelude + "\n" + #"""
start = read_frame()
write_frame(start, 10)
cancel = read_frame()
write_frame(cancel, 8)
shutdown = read_frame()
write_frame(shutdown, 7)
"""#
    let fixture = try StreamingRuntimeFixture(helperSource: source)
    let session = try await fixture.makeSession(vadModelURL: fixture.vadModelURL)
    let otherVAD = fixture.directory.appendingPathComponent("other-vad.bin")
    try Data([2]).write(to: otherVAD)
    await #expect(throws: RetainedWhisperRuntimeError.unsupportedConfiguration) {
        _ = try await session.startStream(
            id: UUID(),
            generation: 0,
            configuration: streamingConfiguration(vadModelPath: otherVAD)
        )
    }
    let streamID = UUID()
    let identity = try await session.startStream(
        id: streamID,
        generation: 0,
        configuration: streamingConfiguration(vadModelPath: fixture.vadModelURL)
    )
    #expect(identity.vadIdentifier?.count == 64)
    #expect(identity.vadIdentifier?.contains(fixture.vadModelURL.path) == false)
    await session.cancelStream(id: streamID, generation: 0)
    await session.shutdown()
    fixture.remove()
}

@Test("Streaming v2 validates PCM bounds before writing")
func streamingRuntimeRejectsMalformedPCMChunk() throws {
    #expect(throws: RetainedWhisperRuntimeError.unsupportedConfiguration) {
        _ = try WhisperStreamAudioChunk(
            sequence: 0,
            sampleOffset: 0,
            sampleCount: 2,
            samplesS16LE: Data([0, 0])
        )
    }
    #expect(throws: RetainedWhisperRuntimeError.unsupportedConfiguration) {
        _ = try WhisperStreamAudioChunk(
            sequence: 0,
            sampleOffset: 0,
            sampleCount: UInt32(WhisperStreamAudioChunk.maximumSampleCount + 1),
            samplesS16LE: Data()
        )
    }
}

@Test("Streaming v2 preserves one-shot transcription and nonzero generations")
func streamingRuntimeSupportsOneShotFinalTranscription() async throws {
    let fixture = try StreamingRuntimeFixture(helperSource: fakeStreamingOneShotHelperSource)
    defer { fixture.remove() }
    let session = try await fixture.makeSession()
    let response = try await session.transcribe(
        WhisperRuntimeRequest(
            id: UUID(),
            generation: 7,
            audioURL: fixture.directory.appendingPathComponent("capture.wav"),
            language: "en",
            prompt: nil,
            threadCount: 1,
            suppressNonSpeechTokens: true,
            suppressRegex: nil,
            vadModelPath: nil,
            beamSize: 1,
            bestOf: 1
        )
    )
    #expect(String(data: response, encoding: .utf8) == #"{"text":"one-shot"}"#)
    await session.shutdown()
}

@Test("Transcription payload appends the vocabulary prompt behind flag bit 2 byte for byte")
func transcriptionPayloadEncodesVocabularyPromptOnFlagBit2() throws {
    let audioURL = URL(fileURLWithPath: "/tmp/capture.wav")
    let prompt = "Language: en. Terms: StenoKit, Steno, Turso, Rowan."
    let vocabulary = "StenoKit, Steno, Turso, Rowan."
    func request(prompt: String?, vocabularyPrompt: String?) -> WhisperRuntimeRequest {
        WhisperRuntimeRequest(
            id: UUID(),
            generation: 0,
            audioURL: audioURL,
            language: "en",
            prompt: prompt,
            vocabularyPrompt: vocabularyPrompt,
            threadCount: 6,
            suppressNonSpeechTokens: true,
            suppressRegex: nil,
            vadModelPath: nil,
            beamSize: 5,
            bestOf: 5
        )
    }
    // Independently assembled frame body: u32 threads, beam, best-of, flags,
    // then bounded strings (0xFFFFFFFF marks an absent optional string).
    func expected(flags: UInt32, prompt: String?, trailing: String?) -> Data {
        var data = Data()
        for value in [UInt32(6), 5, 5, flags] { data.appendPayloadBigEndian(value) }
        for field in [audioURL.path, "en"] as [String] {
            data.appendPayloadBigEndian(UInt32(field.utf8.count)); data.append(contentsOf: Array(field.utf8))
        }
        for optional in [prompt, nil, nil] as [String?] {
            if let optional {
                data.appendPayloadBigEndian(UInt32(optional.utf8.count)); data.append(contentsOf: Array(optional.utf8))
            } else {
                data.appendPayloadBigEndian(UInt32(0xFFFF_FFFF))
            }
        }
        if let trailing {
            data.appendPayloadBigEndian(UInt32(trailing.utf8.count)); data.append(contentsOf: Array(trailing.utf8))
        }
        return data
    }

    #expect(
        try WhisperRuntimeProtocol.transcriptionPayload(for: request(prompt: prompt, vocabularyPrompt: nil))
            == expected(flags: 1, prompt: prompt, trailing: nil)
    )
    #expect(
        try WhisperRuntimeProtocol.transcriptionPayload(for: request(prompt: prompt, vocabularyPrompt: vocabulary))
            == expected(flags: 5, prompt: prompt, trailing: vocabulary)
    )
    // A vocabulary prompt without a recognition prompt has nothing to verify,
    // so the frame is exactly the legacy frame.
    #expect(
        try WhisperRuntimeProtocol.transcriptionPayload(for: request(prompt: nil, vocabularyPrompt: vocabulary))
            == expected(flags: 1, prompt: nil, trailing: nil)
    )
    #expect(whisperVocabularyPrompt(prompt: nil, vocabularyPrompt: "Steno.") == nil)
    #expect(whisperVocabularyPrompt(prompt: "Language: en.", vocabularyPrompt: "") == nil)
    #expect(whisperVocabularyPrompt(prompt: "Language: en.", vocabularyPrompt: vocabulary) == vocabulary)
}

@Test("Stream configuration payload appends the vocabulary prompt after the VAD identity byte for byte")
func streamConfigurationPayloadEncodesVocabularyPromptOnFlagBit2() throws {
    let prompt = "Language: en. Terms: StenoKit, Steno, Turso, Rowan."
    let vocabulary = "StenoKit, Steno, Turso, Rowan."
    let identity = LiveTranscriptionRuntimeIdentity(
        protocolVersion: 2,
        runtimeIdentifier: "runtime",
        modelIdentifier: "model",
        vadIdentifier: nil,
        currentASRContextCount: 1,
        peakASRContextCount: 1
    )
    func configuration(vocabularyPrompt: String?) -> WhisperStreamConfiguration {
        WhisperStreamConfiguration(
            language: "en",
            prompt: prompt,
            vocabularyPrompt: vocabularyPrompt,
            threadCount: 6,
            suppressNonSpeechTokens: true,
            suppressRegex: nil,
            vadModelPath: nil,
            beamSize: 5,
            bestOf: 5
        )
    }
    func expected(flags: UInt32, trailing: String?) -> Data {
        var data = Data()
        for value in [UInt32(6), 5, 5, flags] { data.appendPayloadBigEndian(value) }
        data.appendPayloadBigEndian(UInt32(2)); data.append(contentsOf: Array("en".utf8))
        data.appendPayloadBigEndian(UInt32(prompt.utf8.count)); data.append(contentsOf: Array(prompt.utf8))
        data.appendPayloadBigEndian(UInt32(0xFFFF_FFFF)) // suppress regex
        data.appendPayloadBigEndian(UInt32(0xFFFF_FFFF)) // VAD model path
        data.appendPayloadBigEndian(UInt32(0)) // empty VAD identity
        if let trailing {
            data.appendPayloadBigEndian(UInt32(trailing.utf8.count)); data.append(contentsOf: Array(trailing.utf8))
        }
        return data
    }

    #expect(
        try WhisperStreamingRuntimeProtocol.streamConfigurationPayload(
            configuration(vocabularyPrompt: nil), identity: identity
        ) == expected(flags: 1, trailing: nil)
    )
    #expect(
        try WhisperStreamingRuntimeProtocol.streamConfigurationPayload(
            configuration(vocabularyPrompt: vocabulary), identity: identity
        ) == expected(flags: 5, trailing: vocabulary)
    )
}
}

private extension Data {
    /// Test-side big-endian writer so payload fixtures are assembled independently of the protocol encoder.
    mutating func appendPayloadBigEndian(_ value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }
}

private struct StreamingRuntimeFixture {
    let directory: URL
    let helperURL: URL
    let modelURL: URL
    let vadModelURL: URL
    let pidURL: URL
    let markerURL: URL

    init(helperSource: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-streaming-helper-\(UUID().uuidString)", isDirectory: true)
        helperURL = directory.appendingPathComponent("fake-runtime")
        modelURL = directory.appendingPathComponent("model.bin")
        vadModelURL = directory.appendingPathComponent("vad.bin")
        pidURL = directory.appendingPathComponent("helper.pid")
        markerURL = directory.appendingPathComponent("decode.received")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0]).write(to: modelURL)
        try Data([1]).write(to: vadModelURL)
        try helperSource.write(to: helperURL, atomically: true, encoding: .utf8)
        guard chmod(helperURL.path, S_IRWXU) == 0 else {
            throw RetainedWhisperRuntimeError.helperUnavailable
        }
    }

    func makeSession(
        vadModelURL: URL? = nil
    ) async throws -> any WhisperStreamingRuntimeSession {
        var environment = ProcessInfo.processInfo.environment
        environment["STENO_TEST_HELPER_PID_FILE"] = pidURL.path
        environment["STENO_TEST_HELPER_MARKER_FILE"] = markerURL.path
        return try await ProcessWhisperStreamingRuntimeSessionFactory().makeStreamingSession(
            configuration: .init(
                helperExecutableURL: helperURL,
                modelPath: modelURL,
                threadCount: 1,
                vadModelPath: vadModelURL,
                suppressNonSpeechTokens: true,
                suppressRegex: nil,
                modelLoadTimeout: .seconds(10),
                inferenceTimeout: .seconds(10),
                environment: environment
            )
        )
    }

    func waitForMarker(contents expectedContents: String? = nil) async throws {
        for _ in 0..<1_000 {
            if FileManager.default.fileExists(atPath: markerURL.path) {
                if let expectedContents {
                    let contents = try? String(contentsOf: markerURL, encoding: .utf8)
                    if contents == expectedContents { return }
                } else {
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RetainedWhisperRuntimeError.helperUnavailable
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func streamingConfiguration(vadModelPath: URL? = nil) -> WhisperStreamConfiguration {
    .init(
        language: "en",
        prompt: nil,
        threadCount: 1,
        suppressNonSpeechTokens: true,
        suppressRegex: nil,
        vadModelPath: vadModelPath,
        beamSize: 1,
        bestOf: 1
    )
}

private let fakeStreamingProtocolPrelude = #"""
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
    magic, version, operation, request_id, generation, size = struct.unpack(">IHH16sQI", header)
    return magic, version, operation, request_id, generation, read_exact(size)

def frame(request, operation, payload=b""):
    magic, version, _, request_id, generation, _ = request
    return struct.pack(">IHH16sQI", magic, version, operation, request_id, generation, len(payload)) + payload

identity_payload = b""

def write_frame(request, operation, payload=b"", fragmented=False):
    if operation in (2, 10) and not payload:
        payload = identity_payload
    encoded = frame(request, operation, payload)
    if fragmented:
        for byte in encoded:
            sys.stdout.buffer.write(bytes([byte]))
            sys.stdout.buffer.flush()
    else:
        sys.stdout.buffer.write(encoded)
        sys.stdout.buffer.flush()

def read_string(payload, offset):
    size = struct.unpack(">I", payload[offset:offset + 4])[0]
    offset += 4
    return payload[offset:offset + size], offset + size

def pack_string(value):
    return struct.pack(">I", len(value)) + value

load = read_frame()
_, offset = read_string(load[5], 0)
runtime_identity, offset = read_string(load[5], offset)
model_identity, offset = read_string(load[5], offset)
vad_identity, offset = read_string(load[5], offset)
if offset != len(load[5]):
    raise SystemExit(30)
identity_payload = (
    struct.pack(">II", 2, 0x7f)
    + pack_string(runtime_identity)
    + pack_string(model_identity)
    + pack_string(vad_identity)
    + struct.pack(">II", 1, 1)
)
write_frame(load, 2, fragmented=True)
"""#

private let fakeStreamingLifecycleHelperSource = fakeStreamingProtocolPrelude + "\n" + #"""
start = read_frame()
write_frame(start, 10, fragmented=True)
append = read_frame()
sequence, offset, count = struct.unpack(">QQI", append[5][:20])
write_frame(append, 12, struct.pack(">QQ", sequence, offset + count), fragmented=True)
decode = read_frame()
revision, watermark = struct.unpack(">QQ", decode[5])
stale_text = b"stale"
write_frame(decode, 14, struct.pack(">QQQII", revision + 99, watermark, 1, 0, len(stale_text)) + stale_text)
text = b"hello"
write_frame(decode, 14, struct.pack(">QQQII", revision, watermark, 123, 0, len(text)) + text, fragmented=True)
finish = read_frame()
write_frame(finish, 16, b'{"text":"hello"}', fragmented=True)
shutdown = read_frame()
write_frame(shutdown, 7)
"""#

private let fakeStreamingFinishRaceHelperSource = fakeStreamingProtocolPrelude + "\n" + #"""
start = read_frame()
write_frame(start, 10)
append = read_frame()
sequence, offset, count = struct.unpack(">QQI", append[5][:20])
write_frame(append, 12, struct.pack(">QQ", sequence, offset + count))
decode = read_frame()
revision, watermark = struct.unpack(">QQ", decode[5])
with open(os.environ["STENO_TEST_HELPER_MARKER_FILE"], "w", encoding="utf-8") as handle:
    handle.write("received")
finish = read_frame()
write_frame(finish, 16, b'{"text":"final"}')
shutdown = read_frame()
write_frame(shutdown, 7)
"""#

private let fakeStreamingCancelRestartHelperSource = fakeStreamingProtocolPrelude + "\n" + #"""
for _ in range(2):
    start = read_frame()
    write_frame(start, 10)
    cancel = read_frame()
    write_frame(cancel, 8)
shutdown = read_frame()
write_frame(shutdown, 7)
"""#

private let fakeStreamingCancelDuringFinishHelperSource = fakeStreamingProtocolPrelude + "\n" + #"""
start = read_frame()
write_frame(start, 10)
finish = read_frame()
if finish[2] != 15:
    raise SystemExit(31)
with open(os.environ["STENO_TEST_HELPER_MARKER_FILE"], "w", encoding="utf-8") as handle:
    handle.write("finish-received")
cancel = read_frame()
if cancel[2] != 17:
    raise SystemExit(32)
write_frame(cancel, 8, fragmented=True)
restart = read_frame()
write_frame(restart, 10, fragmented=True)
restart_cancel = read_frame()
write_frame(restart_cancel, 8)
shutdown = read_frame()
write_frame(shutdown, 7)
"""#

private let fakeStreamingAppendFinishRaceHelperSource = fakeStreamingProtocolPrelude + "\n" + #"""
start = read_frame()
write_frame(start, 10)
append = read_frame()
sequence, offset, count = struct.unpack(">QQI", append[5][:20])
with open(os.environ["STENO_TEST_HELPER_MARKER_FILE"], "w", encoding="utf-8") as handle:
    handle.write("append-received")
# Deliberately withhold AudioAccepted until StreamFinish is already framed.
# This proves the client terminal path does not wait on provisional work while
# preserving the append-before-finish order on the single writer.
finish = read_frame()
if finish[2] != 15:
    raise SystemExit(21)
# Queue both ordered responses in one write. The reader resolves AudioAccepted
# first, but the actor is free to service the final continuation before the
# lower-priority append continuation.
sys.stdout.buffer.write(
    frame(append, 12, struct.pack(">QQ", sequence, offset + count))
    + frame(finish, 16, b'{"text":"final-after-append"}')
)
sys.stdout.buffer.flush()
shutdown = read_frame()
write_frame(shutdown, 7)
"""#

private let fakeStreamingAppendDuringHypothesisHelperSource = fakeStreamingProtocolPrelude + "\n" + #"""
start = read_frame()
write_frame(start, 10)
initial = read_frame()
sequence, offset, count = struct.unpack(">QQI", initial[5][:20])
write_frame(initial, 12, struct.pack(">QQ", sequence, offset + count))
decode = read_frame()
revision, watermark = struct.unpack(">QQ", decode[5])
with open(os.environ["STENO_TEST_HELPER_MARKER_FILE"], "w", encoding="utf-8") as handle:
    handle.write("decode-received")
tail = read_frame()
tail_sequence, tail_offset, tail_count = struct.unpack(">QQI", tail[5][:20])
with open(os.environ["STENO_TEST_HELPER_MARKER_FILE"], "w", encoding="utf-8") as handle:
    handle.write("append-received")
# Return the older-window hypothesis before acknowledging the independent tail.
text = b"first-window"
write_frame(decode, 14, struct.pack(">QQQII", revision, watermark, 123, 2, len(text)) + text)
write_frame(tail, 12, struct.pack(">QQ", tail_sequence, tail_offset + tail_count))
finish = read_frame()
write_frame(finish, 16, b'{"text":"complete"}')
shutdown = read_frame()
write_frame(shutdown, 7)
"""#

private let fakeStreamingFinishDuringHypothesisAndAppendHelperSource = fakeStreamingProtocolPrelude + "\n" + #"""
start = read_frame()
write_frame(start, 10)
initial = read_frame()
sequence, offset, count = struct.unpack(">QQI", initial[5][:20])
write_frame(initial, 12, struct.pack(">QQ", sequence, offset + count))
decode = read_frame()
with open(os.environ["STENO_TEST_HELPER_MARKER_FILE"], "w", encoding="utf-8") as handle:
    handle.write("decode-received")
tail = read_frame()
tail_sequence, tail_offset, tail_count = struct.unpack(">QQI", tail[5][:20])
with open(os.environ["STENO_TEST_HELPER_MARKER_FILE"], "w", encoding="utf-8") as handle:
    handle.write("append-received")
# Withhold both responses until terminal framing proves it does not wait on
# provisional inference or the tail acknowledgement.
finish = read_frame()
if finish[2] != 15:
    raise SystemExit(22)
write_frame(tail, 12, struct.pack(">QQ", tail_sequence, tail_offset + tail_count), fragmented=True)
write_frame(finish, 16, b'{"text":"tail-complete"}', fragmented=True)
shutdown = read_frame()
write_frame(shutdown, 7)
"""#

private let fakeStreamingCorrelatedPreviewErrorHelperSource = fakeStreamingProtocolPrelude + "\n" + #"""
start = read_frame()
write_frame(start, 10)
initial = read_frame()
sequence, offset, count = struct.unpack(">QQI", initial[5][:20])
write_frame(initial, 12, struct.pack(">QQ", sequence, offset + count))
decode = read_frame()
revision, watermark = struct.unpack(">QQ", decode[5])
with open(os.environ["STENO_TEST_HELPER_MARKER_FILE"], "w", encoding="utf-8") as handle:
    handle.write("decode-received")
tail = read_frame()
tail_sequence, tail_offset, tail_count = struct.unpack(">QQI", tail[5][:20])
write_frame(decode, 5, struct.pack(">IHHQ", 4, 13, 0, revision), fragmented=True)
write_frame(tail, 12, struct.pack(">QQ", tail_sequence, tail_offset + tail_count), fragmented=True)
finish = read_frame()
write_frame(finish, 16, b'{"text":"correlated-final"}')
shutdown = read_frame()
write_frame(shutdown, 7)
"""#

private let fakeStreamingCorrelatedAppendErrorHelperSource = fakeStreamingProtocolPrelude + "\n" + #"""
start = read_frame()
write_frame(start, 10)
initial = read_frame()
sequence, offset, count = struct.unpack(">QQI", initial[5][:20])
write_frame(initial, 12, struct.pack(">QQ", sequence, offset + count))
decode = read_frame()
revision, watermark = struct.unpack(">QQ", decode[5])
with open(os.environ["STENO_TEST_HELPER_MARKER_FILE"], "w", encoding="utf-8") as handle:
    handle.write("decode-received")
tail = read_frame()
tail_sequence, _, _ = struct.unpack(">QQI", tail[5][:20])
write_frame(tail, 5, struct.pack(">IHHQ", 1, 11, 0, tail_sequence), fragmented=True)
text = b"still-valid"
write_frame(decode, 14, struct.pack(">QQQII", revision, watermark, 456, 1, len(text)) + text, fragmented=True)
cancel = read_frame()
write_frame(cancel, 8)
shutdown = read_frame()
write_frame(shutdown, 7)
"""#

private let fakeStreamingInvalidSpeechEvidenceHelperSource = fakeStreamingProtocolPrelude + "\n" + #"""
start = read_frame()
write_frame(start, 10)
decode = read_frame()
revision, watermark = struct.unpack(">QQ", decode[5])
text = b"invalid"
write_frame(decode, 14, struct.pack(">QQQII", revision, watermark, 789, 3, len(text)) + text)
shutdown = read_frame()
write_frame(shutdown, 7)
"""#

private let fakeStreamingOversizedHelperSource = fakeStreamingProtocolPrelude + "\n" + #"""
start = read_frame()
write_frame(start, 10)
decode = read_frame()
magic, version, _, request_id, generation, _ = decode
sys.stdout.buffer.write(struct.pack(">IHH16sQI", magic, version, 14, request_id, generation, 64 * 1024 * 1024 + 1))
sys.stdout.buffer.flush()
"""#

private let fakeStreamingExitedHelperSource = fakeStreamingProtocolPrelude + "\n" + #"""
start = read_frame()
write_frame(start, 10)
read_frame()
raise SystemExit(19)
"""#

private let fakeStreamingOneShotHelperSource = fakeStreamingProtocolPrelude + "\n" + #"""
transcribe = read_frame()
if transcribe[2] != 3 or transcribe[4] != 7:
    raise SystemExit(20)
write_frame(transcribe, 4, b'{"text":"one-shot"}', fragmented=True)
shutdown = read_frame()
write_frame(shutdown, 7)
"""#
#endif
