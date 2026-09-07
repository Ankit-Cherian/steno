#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import StenoKit

@Suite(.serialized)
struct VadIntegrityFailureTests {
    @Test("Ordinary inference errors retain their one local fallback", arguments: [false, true])
    func ordinaryFailureStillFallsBack(live: Bool) async throws {
        let fixture = try VadIntegrityFixture(failureCategory: 4)
        defer { fixture.remove() }
        let fallback = VadIntegrityFallback()
        let engine = RetainedWhisperTranscriptionEngine(configuration: fixture.configuration, fallback: fallback)
        let transcript: RawTranscript
        if live {
            let identity = try await engine.startLiveTranscription(sessionID: UUID(), controllerGeneration: UUID(), request: .init())
            let frame = LivePCMFrame(sequenceNumber: 0, sampleOffset: 0, pcmS16LE: fixture.pcm)
            try await engine.appendLiveAudio(frame, session: identity)
            transcript = try await engine.finishLiveTranscription(session: identity, canonicalAudioURL: fixture.audioURL,
                streamSummary: .init(sampleCount: UInt64(fixture.pcm.count / 2), byteCount: UInt64(fixture.pcm.count),
                                     frameCount: 1, fnv1a64: LivePCMDigest.fnv1a64(fixture.pcm)), request: .init())
        } else {
            transcript = try await engine.transcribe(audioURL: fixture.audioURL, request: .init())
        }
        #expect(transcript.text == "Please send me.")
        #expect(await fallback.calls == 1)
        await engine.shutdown()
    }

    @Test("Unknown preview evidence permits a healthy complete final with literal Terms")
    func unknownPreviewDoesNotPoisonFinal() async throws {
        let fixture = try VadIntegrityFixture(failureCategory: 0)
        defer { fixture.remove() }
        let fallback = VadIntegrityFallback()
        let engine = RetainedWhisperTranscriptionEngine(configuration: fixture.configuration, fallback: fallback)
        let identity = try await engine.startLiveTranscription(sessionID: UUID(), controllerGeneration: UUID(), request: .init())
        let frame = LivePCMFrame(sequenceNumber: 0, sampleOffset: 0, pcmS16LE: fixture.pcm)
        try await engine.appendLiveAudio(frame, session: identity)
        let preview = try await engine.requestLiveHypothesis(session: identity, revision: 1, decodedAudioWatermark: UInt64(fixture.pcm.count / 2))
        #expect(preview.speechEvidence == .unknown)
        let final = try await engine.finishLiveTranscription(session: identity, canonicalAudioURL: fixture.audioURL,
            streamSummary: .init(sampleCount: UInt64(fixture.pcm.count / 2), byteCount: UInt64(fixture.pcm.count),
                                 frameCount: 1, fnv1a64: LivePCMDigest.fnv1a64(fixture.pcm)), request: .init())
        #expect(final.text == "Terms. Terms. Terms. Please send me the complete recording.")
        #expect(await fallback.calls == 0)
        #expect(try fixture.operations().filter { $0 == 13 }.count == 1)
        #expect(try fixture.operations().filter { $0 == 15 }.count == 1)
        await engine.shutdown()
    }

    @Test("A rejected VAD final does not prevent a new complete recording")
    func freshRecordingCanRecover() async throws {
        let fixture = try VadIntegrityFixture()
        defer { fixture.remove() }
        let fallback = VadIntegrityFallback()
        let engine = RetainedWhisperTranscriptionEngine(configuration: fixture.configuration, fallback: fallback)
        await expectIntegrityFailure(engine: engine, audioURL: fixture.audioURL)
        try Data().write(to: fixture.operationsURL.appendingPathExtension("recover"))
        let newAudio = fixture.directory.appendingPathComponent("new-recording.wav")
        try FileManager.default.copyItem(at: fixture.audioURL, to: newAudio)
        let recovered = try await engine.transcribe(audioURL: newAudio, request: .init())
        #expect(recovered.text == "Terms. Terms. Terms. Please send me the complete recording.")
        // Recovery for a new file must not erase the old canonical failure.
        await expectIntegrityFailure(engine: engine, audioURL: fixture.audioURL)
        #expect(await fallback.calls == 0)
        #expect(try fixture.operations().filter { $0 == 3 }.count == 2)
        await engine.shutdown()
    }

    @Test("VAD integrity wire errors retain their category in both runtime protocols", arguments: [false, true])
    func protocolPreservesIntegrityFailure(streaming: Bool) async throws {
        let fixture = try VadIntegrityFixture()
        defer { fixture.remove() }
        let factory: any WhisperRuntimeSessionFactory = streaming
            ? ProcessWhisperStreamingRuntimeSessionFactory()
            : ProcessWhisperRuntimeSessionFactory()
        let session = try await factory.makeSession(configuration: fixture.configuration)
        do {
            _ = try await session.transcribe(fixture.runtimeRequest)
            Issue.record("Incomplete VAD output was accepted")
        } catch {
            #expect(String(describing: error) == "vadIntegrityFailure")
        }
        await session.shutdown()
    }

    @Test("A VAD integrity failure cannot enter CLI fallback or retry the same canonical final", arguments: [false, true])
    func finalRejectsFallback(live: Bool) async throws {
        let fixture = try VadIntegrityFixture()
        defer { fixture.remove() }
        let fallback = VadIntegrityFallback()
        let engine = RetainedWhisperTranscriptionEngine(configuration: fixture.configuration, fallback: fallback)
        if live {
            let identity = try await engine.startLiveTranscription(
                sessionID: UUID(), controllerGeneration: UUID(), request: .init())
            let frame = LivePCMFrame(sequenceNumber: 0, sampleOffset: 0, pcmS16LE: fixture.pcm)
            try await engine.appendLiveAudio(frame, session: identity)
            do {
                _ = try await engine.finishLiveTranscription(
                    session: identity, canonicalAudioURL: fixture.audioURL,
                    streamSummary: .init(sampleCount: UInt64(fixture.pcm.count / 2),
                                         byteCount: UInt64(fixture.pcm.count), frameCount: 1,
                                         fnv1a64: LivePCMDigest.fnv1a64(fixture.pcm)), request: .init())
                Issue.record("Unsafe final returned a transcript")
            } catch {
                #expect(String(describing: error) == "vadIntegrityFailure")
            }
        } else {
            await expectIntegrityFailure(engine: engine, audioURL: fixture.audioURL)
        }
        await expectIntegrityFailure(engine: engine, audioURL: fixture.audioURL)
        #expect(await fallback.calls == 0)
        #expect(try fixture.operations().filter { $0 == 3 || $0 == 15 }.count == 1)
        await engine.shutdown()
    }

    @Test("Coordinator VAD failure reaches no authoritative sink", arguments: [false, true])
    func coordinatorRejectsIncompleteSpeech(preview: Bool) async throws {
        let fixture = try VadIntegrityFixture()
        defer { fixture.remove() }
        let fallback = VadIntegrityFallback()
        let engine = RetainedWhisperTranscriptionEngine(configuration: fixture.configuration, fallback: fallback)
        let cleanup = VadIntegrityCleanup()
        let transport = VadIntegrityTransport()
        let historyURL = fixture.directory.appendingPathComponent("history.json")
        let history = HistoryStore(storageURL: historyURL, clipboardService: MemoryClipboardService())
        let usage = VadIntegrityUsage()
        let coordinator = SessionCoordinator(
            captureService: VadIntegrityCapture(url: fixture.audioURL), transcriptionEngine: engine,
            cleanupEngine: cleanup, insertionService: InsertionService(transports: [transport]),
            historyStore: history, lexiconService: PersonalLexiconService(entries: []),
            styleProfileService: StyleProfileService(), usageRecorder: usage,
            editorTargetCapture: { _ in .failure(.unsupportedElement) })
        let sessionID = try await coordinator.startPressToTalk(appContext: .unknown,
            options: .init(livePreviewEnabled: preview))
        if preview {
            // An accepted append proves production live setup completed before stop.
            for _ in 0..<1000 {
                if (try? fixture.operations().contains(11)) == true { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(try fixture.operations().contains(11))
        }
        do {
            _ = try await coordinator.stopPressToTalk(sessionID: sessionID)
            Issue.record("Incomplete VAD output reached coordinator completion")
        } catch {
            #expect(String(describing: error) == "vadIntegrityFailure")
        }
        #expect(await fallback.calls == 0)
        #expect(await cleanup.calls == 0)
        #expect(await transport.calls == 0)
        #expect(await usage.calls == 0)
        let reloaded = HistoryStore(storageURL: historyURL, clipboardService: MemoryClipboardService())
        #expect(await reloaded.recent(limit: 10).isEmpty)
        #expect(try fixture.operations().contains(preview ? 15 : 3))
        await coordinator.shutdown()
    }
}

private func expectIntegrityFailure(engine: RetainedWhisperTranscriptionEngine, audioURL: URL) async {
    do {
        _ = try await engine.transcribe(audioURL: audioURL, request: .init())
        Issue.record("Unsafe canonical audio was retried or returned a transcript")
    } catch {
        #expect(String(describing: error) == "vadIntegrityFailure")
    }
}

private actor VadIntegrityFallback: TranscriptionEngine {
    var calls = 0
    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        calls += 1
        // A plausible but truncated result must not hide the primary integrity error.
        return RawTranscript(text: "Please send me.")
    }
}
private actor VadIntegrityCleanup: CleanupEngine {
    var calls = 0
    func cleanup(raw: RawTranscript, profile: StyleProfile, lexicon: PersonalLexicon) async throws -> CleanTranscript {
        calls += 1
        return CleanTranscript(text: raw.text)
    }
}
private actor VadIntegrityTransport: InsertionTransport {
    nonisolated var method: InsertionMethod { .direct }
    var calls = 0
    func insert(text: String, target: AppContext) async throws { calls += 1 }
}
private actor VadIntegrityUsage: UsageAnalyticsRecording {
    var calls = 0
    func record(event: UsageEvent) async throws { calls += 1 }
}
private struct VadIntegrityCapture: AudioCaptureService {
    let url: URL
    func beginCapture(sessionID: SessionID) async throws {}
    func endCapture(sessionID: SessionID) async throws -> URL { url }
    func canonicalCaptureURL(sessionID: SessionID) async -> URL? { url }
    func cancelCapture(sessionID: SessionID) async {}
}

private struct VadIntegrityFixture {
    let directory: URL
    let helperURL: URL
    let modelURL: URL
    let vadURL: URL
    let audioURL: URL
    let operationsURL: URL
    let failureCategory: Int
    let pcm = Data(repeating: 1, count: 6400)

    init(failureCategory: Int = 6) throws {
        self.failureCategory = failureCategory
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vad-integrity-\(UUID())")
        helperURL = directory.appendingPathComponent("runtime")
        modelURL = directory.appendingPathComponent("model.bin")
        vadURL = directory.appendingPathComponent("vad.bin")
        audioURL = directory.appendingPathComponent("capture.wav")
        operationsURL = directory.appendingPathComponent("operations.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0]).write(to: modelURL)
        try Data([1]).write(to: vadURL)
        try vadIntegrityHelper.write(to: helperURL, atomically: true, encoding: .utf8)
        guard chmod(helperURL.path, S_IRWXU) == 0 else { throw RetainedWhisperRuntimeError.helperUnavailable }
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        append(UInt32(36 + pcm.count)); wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(16000))
        append(UInt32(32000)); append(UInt16(2)); append(UInt16(16))
        wav.append(Data("data".utf8)); append(UInt32(pcm.count)); wav.append(pcm)
        try wav.write(to: audioURL)
    }
    var configuration: RetainedWhisperTranscriptionConfiguration {
        var environment = ProcessInfo.processInfo.environment
        environment["STENO_TEST_VAD_OPERATIONS"] = operationsURL.path
        environment["STENO_TEST_VAD_ERROR_CATEGORY"] = String(failureCategory)
        return .init(helperExecutableURL: helperURL, modelPath: modelURL, threadCount: 1,
                     vadModelPath: vadURL, suppressNonSpeechTokens: true, suppressRegex: nil,
                     modelLoadTimeout: .seconds(10), inferenceTimeout: .seconds(10), environment: environment)
    }
    var runtimeRequest: WhisperRuntimeRequest {
        .init(id: UUID(), generation: 7, audioURL: audioURL, language: "en", prompt: nil,
              threadCount: 1, suppressNonSpeechTokens: true, suppressRegex: nil,
              vadModelPath: vadURL, beamSize: 1, bestOf: 1)
    }
    func operations() throws -> [Int] {
        try String(contentsOf: operationsURL, encoding: .utf8).split(separator: "\n").compactMap { Int($0) }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private let vadIntegrityHelper = #"""
#!/usr/bin/env python3
import os, struct, sys
def read_exact(n):
    value = b''
    while len(value) < n:
        part = sys.stdin.buffer.read(n-len(value))
        if not part: raise SystemExit(0)
        value += part
    return value
def read_frame():
    header = struct.unpack('>IHH16sQI', read_exact(36))
    return header, read_exact(header[5])
def write_frame(frame, op, payload=b''):
    h, _ = frame
    sys.stdout.buffer.write(struct.pack('>IHH16sQI', h[0], h[1], op, h[3], h[4], len(payload))+payload)
    sys.stdout.buffer.flush()
def read_string(data, offset):
    n = struct.unpack('>I', data[offset:offset+4])[0]
    return data[offset+4:offset+4+n], offset+4+n
def pack_string(value): return struct.pack('>I', len(value))+value
load = read_frame()
identity = b''
if load[0][1] == 2:
    _, offset = read_string(load[1], 0)
    runtime, offset = read_string(load[1], offset)
    model, offset = read_string(load[1], offset)
    vad, offset = read_string(load[1], offset)
    identity = struct.pack('>II', 2, 0x7f)+pack_string(runtime)+pack_string(model)+pack_string(vad)+struct.pack('>II', 1, 1)
write_frame(load, 2, identity)
while True:
    frame = read_frame()
    h, payload = frame
    op = h[2]
    with open(os.environ['STENO_TEST_VAD_OPERATIONS'], 'a') as log: log.write(str(op)+'\n')
    if op == 6:
        write_frame(frame, 7)
        break
    if op == 9: write_frame(frame, 10, identity)
    elif op == 11:
        seq, offset, count = struct.unpack('>QQI', payload[:20])
        write_frame(frame, 12, struct.pack('>QQ', seq, offset+count))
    elif op == 13:
        revision, watermark = struct.unpack('>QQ', payload)
        write_frame(frame, 14, struct.pack('>QQQI', revision, watermark, 1, 0)+pack_string(b''))
    elif op == 17: write_frame(frame, 8)
    elif op in (3, 15):
        category = 0 if os.path.exists(os.environ['STENO_TEST_VAD_OPERATIONS']+'.recover') else int(os.environ['STENO_TEST_VAD_ERROR_CATEGORY'])
        if category == 0:
            write_frame(frame, 4 if op == 3 else 16, b'{"transcription":[{"text":"Terms. Terms. Terms. Please send me the complete recording.","offsets":{"from":0,"to":200}}]}')
            continue
        error = struct.pack('>I', category)
        if h[1] == 2: error += struct.pack('>HHQ', op, 0, 2**64-1)
        write_frame(frame, 5, error)
    else: raise SystemExit(40)
"""#
#endif
