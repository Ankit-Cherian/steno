import CryptoKit
import Foundation
import Testing
@testable import StenoKit

/// Explicitly opted-in local inference; ordinary package runs skip this suite.
/// Supply STENO_TEST_PROMPT_INTEGRATION=1, STENO_TEST_RETAINED_HELPER,
/// STENO_TEST_WHISPER_MODEL, STENO_TEST_WHISPER_VAD (optional),
/// STENO_TEST_PROMPT_MANIFEST, and STENO_TEST_PROMPT_RECEIPTS.
/// The manifest contains publicOrSyntheticAudio: true and fixtures with id,
/// audio (relative to the manifest), expectedText, and hotTerms fields. Required
/// ids are ordinary, literal-terms, repeated-terms, vocabulary, pauses, silence.
/// Audio must be canonical 16 kHz mono PCM WAV. expectedText is the independently
/// supplied spoken reference, not output copied from the engine under test.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["STENO_TEST_PROMPT_INTEGRATION"] == "1"))
struct PromptIsolationIntegrationTests {
    @Test("Real retained decoding preserves authoritative text across preview modes and production sinks")
    func realRuntimePreviewFinalParity() async throws {
        let environment = ProcessInfo.processInfo.environment
        func requiredURL(_ key: String) throws -> URL {
            let value = try #require(environment[key], "Explicit fixture configuration missing: \(key)")
            return URL(fileURLWithPath: value)
        }
        let manifestURL = try requiredURL("STENO_TEST_PROMPT_MANIFEST")
        let output = try requiredURL("STENO_TEST_PROMPT_RECEIPTS")
        let manifest = try JSONDecoder().decode(PromptFixtureManifest.self, from: Data(contentsOf: manifestURL))
        try #require(manifest.publicOrSyntheticAudio, "Private recordings are excluded from this harness")
        let requiredIDs: Set<String> = ["ordinary", "literal-terms", "repeated-terms", "vocabulary", "pauses", "silence"]
        try #require(requiredIDs.isSubset(of: Set(manifest.fixtures.map(\.id))))
        try #require(Set(manifest.fixtures.map(\.id)).count == manifest.fixtures.count)
        let engine = RetainedWhisperTranscriptionEngine(
            configuration: .init(
                helperExecutableURL: try requiredURL("STENO_TEST_RETAINED_HELPER"),
                modelPath: try requiredURL("STENO_TEST_WHISPER_MODEL"),
                threadCount: 6,
                vadModelPath: environment["STENO_TEST_WHISPER_VAD"].map(URL.init(fileURLWithPath:)),
                suppressNonSpeechTokens: true,
                suppressRegex: nil
            ),
            fallback: PromptUnexpectedFallback()
        )
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        do {
            for fixture in manifest.fixtures {
                try #require(fixture.id.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil)
                let source = manifestURL.deletingLastPathComponent().appendingPathComponent(fixture.audio)
                let audio = try Data(contentsOf: source)
                var trials: [PromptTrialReceipt] = []
                for enabled in [true, false] {
                    let trial = try await runPromptTrial(
                        fixture: fixture, audio: audio, enabled: enabled, engine: engine
                    )
                    trials.append(trial)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(trial).write(
                        to: output.appendingPathComponent("\(fixture.id)-\(enabled ? "preview" : "final").json"),
                        options: .atomic
                    )
                    assertPromptTrial(trial, fixture: fixture)
                }
                #expect(trials[0].rawFinals == trials[1].rawFinals, "\(fixture.id): raw final changed with preview")
                #expect(trials[0].cleaned == trials[1].cleaned, "\(fixture.id): cleanup changed with preview")
                #expect(trials[0].inserted == trials[1].inserted, "\(fixture.id): insertion changed with preview")
                #expect(trials[0].historyRaw == trials[1].historyRaw)
                #expect(trials[0].historyClean == trials[1].historyClean)
            }
            await engine.shutdown()
        } catch {
            await engine.shutdown()
            throw error
        }
    }
}

private struct PromptFixtureManifest: Decodable {
    var publicOrSyntheticAudio: Bool
    var fixtures: [PromptFixture]
}

private struct PromptFixture: Decodable {
    var id: String
    var audio: String
    var expectedText: String
    var hotTerms: [String]
}

private struct PromptPreviewReceipt: Codable, Sendable {
    var text: String
    var watermark: UInt64
    var evidence: String
}

private struct PromptRequestReceipt: Codable, Sendable {
    var path: String
    var hotTerms: [String]
    var prompt: String?
}

private struct PromptTrialReceipt: Codable, Sendable {
    var fixtureID: String
    var fixtureSHA256: String
    var previewEnabled: Bool
    var enginePreviews: [PromptPreviewReceipt]
    var displayedPreviews: [String]
    var rawFinals: [String]
    var finalPaths: [String]
    var cleaned: [String]
    var inserted: [String]
    var historyRaw: [String]
    var historyClean: [String]
    var status: String
    var liveUnavailable: [String]
    var requests: [PromptRequestReceipt]
    var canonicalByteCount: UInt64?
    var canonicalDigest: UInt64?
}

private func promptWords(_ text: String) -> [String] {
    text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
}

private func assertPromptTrial(_ trial: PromptTrialReceipt, fixture: PromptFixture) {
    #expect(trial.rawFinals.count == 1, "\(fixture.id): exactly one authoritative decoder result")
    #expect(trial.finalPaths == [trial.previewEnabled ? "live-finish" : "transcribe"])
    #expect(trial.liveUnavailable.isEmpty)
    if trial.previewEnabled {
        #expect(!trial.enginePreviews.isEmpty, "\(fixture.id): real provisional decode was not exercised")
        #expect(trial.canonicalByteCount != nil)
    } else {
        #expect(trial.enginePreviews.isEmpty)
        #expect(trial.displayedPreviews.isEmpty)
    }
    let expectedWords = promptWords(fixture.expectedText)
    let expectedTermsCount = expectedWords.filter { $0 == "terms" }.count
    for text in trial.rawFinals + trial.cleaned + trial.inserted + trial.historyRaw + trial.historyClean {
        #expect(promptWords(text) == expectedWords, "\(fixture.id): reference mismatch at authoritative boundary: \(text)")
        #expect(promptWords(text).filter { $0 == "terms" }.count == expectedTermsCount)
    }
    if expectedTermsCount == 0 {
        for preview in trial.enginePreviews {
            #expect(!promptWords(preview.text).contains("terms"), "\(fixture.id): raw preview invented Terms")
        }
        for preview in trial.displayedPreviews {
            #expect(!promptWords(preview).contains("terms"), "\(fixture.id): displayed preview invented Terms")
        }
    }
    if expectedWords.isEmpty {
        #expect(trial.status == InsertionStatus.noSpeech.rawValue)
        #expect(trial.cleaned.isEmpty)
        #expect(trial.inserted.isEmpty)
        #expect(trial.historyRaw.isEmpty)
        #expect(trial.historyClean.isEmpty)
    } else {
        #expect(trial.status == InsertionStatus.inserted.rawValue)
        #expect(trial.cleaned.count == 1)
        #expect(trial.inserted == trial.cleaned)
        #expect(trial.historyRaw == trial.rawFinals)
        #expect(trial.historyClean == trial.cleaned)
        if trial.previewEnabled {
            #expect(!trial.displayedPreviews.isEmpty, "\(fixture.id): accepted display snapshot missing")
        }
    }
}

private func runPromptTrial(
    fixture: PromptFixture,
    audio: Data,
    enabled: Bool,
    engine: RetainedWhisperTranscriptionEngine
) async throws -> PromptTrialReceipt {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-prompt-integration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let historyURL = scratch.appendingPathComponent("history.json")
    let history = HistoryStore(storageURL: historyURL, clipboardService: MemoryClipboardService())
    let capture = try PromptStreamingCapture(audio: audio, directory: scratch)
    let observation = PromptObservation()
    let observedEngine = PromptObservedEngine(base: engine, observation: observation)
    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: observedEngine,
        cleanupEngine: PromptObservedCleanup(observation: observation),
        insertionService: InsertionService(transports: [PromptCaptureTransport(observation: observation)]),
        historyStore: history,
        lexiconService: PersonalLexiconService(entries: fixture.hotTerms.map {
            LexiconEntry(term: $0, preferred: $0, scope: .global)
        }),
        styleProfileService: StyleProfileService(),
        snippetService: SnippetService(snippets: []),
        liveSnapshotHandler: { await observation.snapshot($0) },
        liveUnavailableHandler: { _, reason in await observation.unavailable(reason) },
        editorTargetCapture: { _ in .failure(.unsupportedElement) }
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: AppContext(bundleIdentifier: "com.example.prompt-integration", appName: "Fixture Editor"),
        options: .init(livePreviewEnabled: enabled, nearbyContextEnabled: false, languageHints: ["en-US"])
    )
    do {
        try await capture.waitForCompleteAudio()
        if enabled {
            let deadline = ContinuousClock.now.advanced(by: .seconds(120))
            while !(await observation.hasPreview(at: capture.sampleCount)) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            try #require(await observation.hasPreview(at: capture.sampleCount), "No provisional decode of complete fixture")
            // Allow the coordinator to reduce the just-returned engine event.
            try await Task.sleep(for: .milliseconds(100))
        }
        try await coordinator.endPressToTalkCapture(sessionID: sessionID)
        let result = try await coordinator.completePressToTalk(sessionID: sessionID)
        // Reopen from disk to prove actual persistence, not just actor memory.
        let reloaded = HistoryStore(storageURL: historyURL, clipboardService: MemoryClipboardService())
        let entries = await reloaded.recent(limit: 10)
        var receipt = await observation.receipt(fixture: fixture, audio: audio, enabled: enabled)
        receipt.status = result.status.rawValue
        receipt.historyRaw = entries.map(\.rawText)
        receipt.historyClean = entries.map(\.cleanText)
        if enabled {
            #expect(receipt.canonicalByteCount == UInt64(capture.pcm.count))
            #expect(receipt.canonicalDigest == LivePCMDigest.fnv1a64(capture.pcm))
        }
        await coordinator.shutdown()
        return receipt
    } catch {
        await coordinator.cancel(sessionID: sessionID)
        await coordinator.shutdown()
        throw error
    }
}

/// A growing canonical file exercises the coordinator's production frame
/// streamer. Each half-second PCM chunk arrives every 250 ms; pauses belong to
/// the audio itself. This is deterministic file replay, not microphone timing.
private actor PromptStreamingCapture: AudioCaptureService {
    nonisolated let pcm: Data
    nonisolated var sampleCount: UInt64 { UInt64(pcm.count / 2) }
    private let audio: Data
    private let payloadOffset: Int
    private let directory: URL
    private var url: URL?
    private var writer: Task<Void, Error>?

    init(audio: Data, directory: URL) throws {
        func u32(_ offset: Int) -> Int {
            Int(audio[offset]) | Int(audio[offset + 1]) << 8
                | Int(audio[offset + 2]) << 16 | Int(audio[offset + 3]) << 24
        }
        guard audio.count >= 44,
              String(decoding: audio[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: audio[8..<12], as: UTF8.self) == "WAVE" else {
            throw CanonicalWAVFrameStreamerError.invalidContainer
        }
        var offset = 12
        var dataOffset: Int?
        while offset + 8 <= audio.count {
            let count = u32(offset + 4)
            guard count <= audio.count - offset - 8 else {
                throw CanonicalWAVFrameStreamerError.invalidChunkLayout
            }
            if String(decoding: audio[offset..<offset + 4], as: UTF8.self) == "data" {
                guard offset + 8 + count == audio.count, count.isMultiple(of: 2) else {
                    throw CanonicalWAVFrameStreamerError.inconsistentDataSize
                }
                dataOffset = offset + 8
                break
            }
            offset += 8 + count + count % 2
        }
        guard let dataOffset else { throw CanonicalWAVFrameStreamerError.invalidChunkLayout }
        self.audio = audio
        self.pcm = Data(audio[dataOffset...])
        self.payloadOffset = dataOffset
        self.directory = directory
    }

    func beginCapture(sessionID: SessionID) async throws {
        let destination = directory.appendingPathComponent("\(sessionID.uuidString).wav")
        try audio.prefix(payloadOffset).write(to: destination)
        url = destination
        let audio = self.audio
        let start = payloadOffset
        writer = Task {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try handle.seekToEnd()
            for offset in stride(from: start, to: audio.count, by: 16_000) {
                try Task.checkCancellation()
                try handle.write(contentsOf: audio[offset..<min(offset + 16_000, audio.count)])
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func canonicalCaptureURL(sessionID: SessionID) async -> URL? { url }
    func waitForCompleteAudio() async throws { try await writer?.value }
    func endCapture(sessionID: SessionID) async throws -> URL {
        try await waitForCompleteAudio()
        return try #require(url)
    }
    func cancelCapture(sessionID: SessionID) async {
        writer?.cancel()
        _ = try? await writer?.value
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}

private actor PromptObservation {
    var previews: [PromptPreviewReceipt] = []
    var displayed: [String] = []
    var finals: [String] = []
    var paths: [String] = []
    var cleaned: [String] = []
    var inserted: [String] = []
    var unavailableReasons: [String] = []
    var requests: [PromptRequestReceipt] = []
    var summary: LivePCMStreamSummary?

    func preview(_ event: LiveTranscriptionEvent) {
        previews.append(.init(text: event.fullHypothesisText, watermark: event.decodedAudioWatermark,
                              evidence: String(describing: event.speechEvidence)))
    }
    func hasPreview(at watermark: UInt64) -> Bool { previews.contains { $0.watermark >= watermark } }
    func snapshot(_ snapshot: LiveTranscriptionSnapshot) {
        if snapshot.phase == .active, snapshot.lastAcceptedRevision != nil, !snapshot.provisionalText.isEmpty {
            displayed.append(snapshot.provisionalText)
        }
    }
    func unavailable(_ reason: LiveTranscriptUnavailableReason) { unavailableReasons.append(String(describing: reason)) }
    func request(_ request: TranscriptionRequest, path: String) {
        requests.append(.init(path: path, hotTerms: request.hotTerms,
                              prompt: WhisperRuntimeConfiguration.buildPrompt(for: request)))
    }
    func final(_ raw: RawTranscript, path: String, summary: LivePCMStreamSummary? = nil) {
        finals.append(raw.text)
        paths.append(path)
        self.summary = summary
    }
    func clean(_ text: String) { cleaned.append(text) }
    func insert(_ text: String) { inserted.append(text) }
    func receipt(fixture: PromptFixture, audio: Data, enabled: Bool) -> PromptTrialReceipt {
        .init(fixtureID: fixture.id,
              fixtureSHA256: SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined(),
              previewEnabled: enabled, enginePreviews: previews, displayedPreviews: displayed,
              rawFinals: finals, finalPaths: paths, cleaned: cleaned, inserted: inserted,
              historyRaw: [], historyClean: [], status: "pending", liveUnavailable: unavailableReasons,
              requests: requests,
              canonicalByteCount: summary?.byteCount, canonicalDigest: summary?.fnv1a64)
    }
}

private struct PromptObservedEngine: LiveTranscriptionEngine {
    let base: RetainedWhisperTranscriptionEngine
    let observation: PromptObservation
    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        await observation.request(request, path: "transcribe")
        let result = try await base.transcribe(audioURL: audioURL, request: request)
        await observation.final(result, path: "transcribe")
        return result
    }
    func startLiveTranscription(sessionID: SessionID, controllerGeneration: UUID,
                                request: TranscriptionRequest) async throws -> LiveTranscriptionSession {
        await observation.request(request, path: "live-start")
        return try await base.startLiveTranscription(sessionID: sessionID, controllerGeneration: controllerGeneration, request: request)
    }
    func appendLiveAudio(_ frame: LivePCMFrame, session: LiveTranscriptionSession) async throws {
        try await base.appendLiveAudio(frame, session: session)
    }
    func requestLiveHypothesis(session: LiveTranscriptionSession, revision: UInt64,
                               decodedAudioWatermark: UInt64) async throws -> LiveTranscriptionEvent {
        let result = try await base.requestLiveHypothesis(session: session, revision: revision,
                                                          decodedAudioWatermark: decodedAudioWatermark)
        await observation.preview(result)
        return result
    }
    func finishLiveTranscription(session: LiveTranscriptionSession, canonicalAudioURL: URL,
                                 streamSummary: LivePCMStreamSummary, request: TranscriptionRequest) async throws -> RawTranscript {
        await observation.request(request, path: "live-finish")
        let result = try await base.finishLiveTranscription(session: session, canonicalAudioURL: canonicalAudioURL,
                                                            streamSummary: streamSummary, request: request)
        await observation.final(result, path: "live-finish", summary: streamSummary)
        return result
    }
    func cancelLiveTranscription(session: LiveTranscriptionSession) async { await base.cancelLiveTranscription(session: session) }
    // The suite owns the retained engine across paired coordinator lifetimes.
    func shutdown() async {}
    func unloadRetainedResources() async {}
}

private struct PromptObservedCleanup: CleanupEngine {
    let observation: PromptObservation
    func cleanup(raw: RawTranscript, profile: StyleProfile, lexicon: PersonalLexicon) async throws -> CleanTranscript {
        let result = try await RuleBasedCleanupEngine().cleanup(raw: raw, profile: profile, lexicon: lexicon)
        await observation.clean(result.text)
        return result
    }
}

private struct PromptCaptureTransport: InsertionTransport {
    let observation: PromptObservation
    let method: InsertionMethod = .direct
    func insert(text: String, target: AppContext) async throws { await observation.insert(text) }
}

private struct PromptUnexpectedFallback: TranscriptionEngine {
    struct FallbackWasUsed: Error {}
    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        throw FallbackWasUsed()
    }
}
