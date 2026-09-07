import AppKit
import Foundation
import Testing
@testable import Steno
import StenoKit

@Suite(.serialized)
@MainActor
struct DictationControllerIdleAudioStressTests {
    @Test("Media result timing preserves complete canonical audio across both recording modes",
          arguments: [false, true], IdleAudioMediaCase.allCases)
    func canonicalAudioSurvivesMediaCompletion(
        handsFree: Bool,
        mediaCase: IdleAudioMediaCase
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoIdleAudioStress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let mediaGate = IdleAudioGate(open: !mediaCase.delayed)
        let previewGate = IdleAudioGate(open: false)
        let media = IdleAudioMediaService(gate: mediaGate, returnsToken: mediaCase.returnsToken)
        let capture = IdleAudioCapture(directory: directory)
        let engine = IdleAudioEngine(previewGate: previewGate)
        let transport = IdleAudioTransport()
        let clipboard = MemoryClipboardService()
        let historyURL = directory.appendingPathComponent("history.json")
        let history = HistoryStore(storageURL: historyURL, clipboardService: clipboard)
        let coordinator = SessionCoordinator(
            captureService: capture,
            transcriptionEngine: engine,
            cleanupEngine: IdleAudioCleanup(),
            insertionService: InsertionService(transports: [transport]),
            historyStore: history,
            lexiconService: PersonalLexiconService(entries: []),
            styleProfileService: StyleProfileService(),
            editorTargetCapture: { _ in .failure(.unsupportedElement) }
        )
        let controller = makeTestDictationController(
            hotkey: IdleAudioHotkey(),
            mediaInterruption: media,
            preferencesStore: AppPreferencesStore(storageURL: directory.appendingPathComponent("preferences.json")),
            coordinator: coordinator,
            historyStore: history,
            usageAnalyticsStore: UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json")),
            legacyHistoryURL: directory.appendingPathComponent("legacy.json")
        )
        controller.preferences.dictation.showLiveTranscriptWhileRecording = true
        controller.preferences.media.pauseDuringHandsFree = true
        controller.preferences.media.pauseDuringPressToTalk = true

        do {
            // A second recording exposes stale first-session completion or PCM reuse.
            for recording in 1...2 {
                await previewGate.close()
                await mediaGate.setOpen(!mediaCase.delayed)
                if handsFree { controller.toggleHandsFree() } else { controller.pressToTalkStart() }
                try #require(await idleAudioEventually { await capture.startedCount() == recording },
                             "Capture did not start: status=\(controller.status), error=\(controller.lastError)")
                try #require(await idleAudioEventually { await media.begins == recording })

                let pcm = idleAudioPCM(recording: recording)
                await engine.expect(pcm: pcm, recording: recording)
                // Match the recorder's growing-file convention: data length stays
                // zero until stop, although complete PCM bytes already follow it.
                try await capture.append(pcm)
                try #require(await idleAudioEventually { await engine.previewStarts() >= recording })

                if handsFree { controller.toggleHandsFree() } else { controller.pressToTalkStop() }
                #expect(await idleAudioEventually { await capture.endedCount() == recording },
                        "Capture must close while the media probe and preview are still suspended")
                // Finalization may cancel the suspended preview and finish directly.

                await mediaGate.open()
                await previewGate.open()
                try #require(await idleAudioEventually { await transport.texts().count == recording })
                try #require(await idleAudioEventually { @MainActor in controller.status == "Transcript inserted." })
                try #require(await idleAudioEventually { @MainActor in controller.recordingLifecycleState == .idle })
                #expect(controller.lastTranscript == IdleAudioEngine.reference(recording))
            }
            controller.teardown()
            await coordinator.shutdown()
            let expected = (1...2).map(IdleAudioEngine.reference)
            #expect(await transport.texts() == expected)
            #expect(await engine.finals() == expected)
            #expect(await capture.cancelledCount() == 0)
            #expect(await media.ends == (mediaCase.returnsToken ? 2 : 0))
            let reloaded = HistoryStore(storageURL: historyURL, clipboardService: clipboard)
            let entries = await reloaded.recent(limit: 10)
            #expect(entries.count == 2)
            #expect(Set(entries.map(\.rawText)) == Set(expected))
            #expect(Set(entries.map(\.cleanText)) == Set(expected))
        } catch {
            await mediaGate.open()
            await previewGate.open()
            controller.teardown()
            await coordinator.shutdown()
            throw error
        }
    }
}

enum IdleAudioMediaCase: String, CaseIterable, Sendable {
    case idleImmediate, idleDelayed, playingImmediate, playingDelayed
    var delayed: Bool { self == .idleDelayed || self == .playingDelayed }
    var returnsToken: Bool { self == .playingImmediate || self == .playingDelayed }
}

private actor IdleAudioGate {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(open: Bool) { isOpen = open }
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func setOpen(_ value: Bool) { if value { open() } else { close() } }
    func close() { isOpen = false }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class IdleAudioMediaService: MediaInterruptionService {
    let gate: IdleAudioGate
    let returnsToken: Bool
    private(set) var begins = 0
    private(set) var ends = 0
    init(gate: IdleAudioGate, returnsToken: Bool) {
        self.gate = gate
        self.returnsToken = returnsToken
    }
    func beginInterruption() async -> MediaInterruptionToken? {
        begins += 1
        await gate.wait()
        return returnsToken ? MediaInterruptionToken() : nil
    }
    func endInterruption(token: MediaInterruptionToken) async { ends += 1 }
}

private actor IdleAudioCapture: AudioCaptureService {
    let directory: URL
    private var active: SessionID?
    private var activeURL: URL?
    private var pcm = Data()
    private var starts = 0
    private var ends = 0
    private var cancels = 0
    init(directory: URL) { self.directory = directory }
    func beginCapture(sessionID: SessionID) async throws {
        try #require(active == nil)
        active = sessionID
        let url = directory.appendingPathComponent("\(sessionID.uuidString).wav")
        activeURL = url
        pcm = Data()
        try idleAudioWAV(Data(), finalized: false).write(to: url)
        starts += 1
    }
    func append(_ bytes: Data) throws {
        let url = try #require(activeURL)
        try #require(active != nil)
        pcm.append(bytes)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
    }
    func canonicalCaptureURL(sessionID: SessionID) async -> URL? {
        active == sessionID ? activeURL : nil
    }
    func endCapture(sessionID: SessionID) async throws -> URL {
        try #require(active == sessionID)
        let url = try #require(activeURL)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: idleAudioWAV(pcm, finalized: true).prefix(44))
        try handle.synchronize()
        active = nil
        activeURL = nil
        ends += 1
        return url
    }
    func cancelCapture(sessionID: SessionID) async {
        guard active == sessionID else { return }
        active = nil
        activeURL = nil
        cancels += 1
    }
    func startedCount() -> Int { starts }
    func endedCount() -> Int { ends }
    func cancelledCount() -> Int { cancels }
}

private actor IdleAudioEngine: LiveTranscriptionEngine {
    let previewGate: IdleAudioGate
    private var expected: [UInt64: Int] = [:]
    private var streams: [SessionID: Data] = [:]
    private var previewSessions: Set<SessionID> = []
    private var finalTexts: [String] = []
    private let identity = LiveTranscriptionRuntimeIdentity(
        protocolVersion: 2, runtimeIdentifier: "idle-audio-test", modelIdentifier: "pcm-identity",
        vadIdentifier: nil, currentASRContextCount: 1, peakASRContextCount: 1
    )
    init(previewGate: IdleAudioGate) { self.previewGate = previewGate }
    nonisolated static func reference(_ recording: Int) -> String {
        "Recording \(recording == 1 ? "one" : "two") contains every sample."
    }
    func expect(pcm: Data, recording: Int) { expected[LivePCMDigest.fnv1a64(pcm)] = recording }
    func previewStarts() -> Int { previewSessions.count }
    func finals() -> [String] { finalTexts }
    func startLiveTranscription(
        sessionID: SessionID, controllerGeneration: UUID, request: TranscriptionRequest
    ) async throws -> LiveTranscriptionSession {
        streams[sessionID] = Data()
        return LiveTranscriptionSession(sessionID: sessionID, controllerGeneration: controllerGeneration,
                                        runtimeGeneration: 1, runtimeIdentity: identity)
    }
    func appendLiveAudio(_ frame: LivePCMFrame, session: LiveTranscriptionSession) async throws {
        let existing = try #require(streams[session.sessionID])
        #expect(frame.sampleOffset == UInt64(existing.count / 2))
        streams[session.sessionID, default: Data()].append(frame.pcmS16LE)
    }
    func requestLiveHypothesis(
        session: LiveTranscriptionSession, revision: UInt64, decodedAudioWatermark: UInt64
    ) async throws -> LiveTranscriptionEvent {
        previewSessions.insert(session.sessionID)
        await previewGate.wait()
        try Task.checkCancellation()
        return LiveTranscriptionEvent(session: session, revision: revision,
                                      decodedAudioWatermark: decodedAudioWatermark,
                                      emittedAtMonotonicNanos: 1,
                                      fullHypothesisText: "Terms Terms Terms",
                                      speechEvidence: .speechDetected)
    }
    func finishLiveTranscription(
        session: LiveTranscriptionSession, canonicalAudioURL: URL,
        streamSummary: LivePCMStreamSummary, request: TranscriptionRequest
    ) async throws -> RawTranscript {
        let audio = try Data(contentsOf: canonicalAudioURL)
        let pcm = Data(audio.dropFirst(44))
        let finishedStream = streams.removeValue(forKey: session.sessionID)
        let streamed = try #require(finishedStream)
        #expect(streamed == pcm)
        #expect(streamSummary.byteCount == UInt64(pcm.count))
        #expect(streamSummary.sampleCount == UInt64(pcm.count / 2))
        #expect(streamSummary.fnv1a64 == LivePCMDigest.fnv1a64(pcm))
        return try result(pcm)
    }
    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        Issue.record("The live path must finish rather than silently use the fallback")
        return try result(Data(contentsOf: audioURL).dropFirst(44))
    }
    func cancelLiveTranscription(session: LiveTranscriptionSession) async { streams[session.sessionID] = nil }
    private func result(_ pcm: Data) throws -> RawTranscript {
        let recording = try #require(expected[LivePCMDigest.fnv1a64(pcm)])
        let text = Self.reference(recording)
        finalTexts.append(text)
        return RawTranscript(text: text, durationMS: pcm.count * 1000 / 32000)
    }
}

private struct IdleAudioCleanup: CleanupEngine {
    func cleanup(raw: RawTranscript, profile: StyleProfile, lexicon: PersonalLexicon) async throws -> CleanTranscript {
        CleanTranscript(text: raw.text)
    }
}

private actor IdleAudioTransport: InsertionTransport {
    nonisolated var method: InsertionMethod { .direct }
    private var values: [String] = []
    func insert(text: String, target: AppContext) async throws { values.append(text) }
    func texts() -> [String] { values }
}

@MainActor
private final class IdleAudioHotkey: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16? = 79
    func start() {}
    func stop() {}
}

private func idleAudioPCM(recording: Int) -> Data {
    var data = Data(capacity: 96000)
    for index in 0..<48000 {
        var sample = Int16(recording * 1000 + index % 251).littleEndian
        withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
    }
    return data
}

private func idleAudioWAV(_ pcm: Data, finalized: Bool) -> Data {
    var data = Data("RIFF".utf8)
    func append<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    append(UInt32(finalized ? 36 + pcm.count : 0))
    data.append(Data("WAVEfmt ".utf8))
    append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(UInt32(16000)); append(UInt32(32000)); append(UInt16(2)); append(UInt16(16))
    data.append(Data("data".utf8))
    append(UInt32(finalized ? pcm.count : 0))
    data.append(pcm)
    return data
}

private func idleAudioEventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<600 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}
