import Foundation
import Testing
import StenoKitTestSupport
@testable import StenoKit

struct PromptVerificationRichOutputTests {
    @Test("WhisperTranscriptDecoder ignores verification on replaced-window rich JSON")
    func decoderIgnoresVerificationKeyForReplacedWindow() throws {
        let withVerification = replacedWindowRichJSON(includeVerification: true)
        let withoutVerification = replacedWindowRichJSON(includeVerification: false)
        #expect(withVerification != withoutVerification)

        let decodedWith = try #require(WhisperTranscriptDecoder.decodeRichJSON(withVerification))
        let decodedWithout = try #require(WhisperTranscriptDecoder.decodeRichJSON(withoutVerification))
        #expect(decodedWith == decodedWithout)
        assertReplacedWindowTranscript(decodedWith)
        assertReplacedWindowTranscript(decodedWithout)
    }

    @Test("WhisperTranscriptDecoder accepts dropped verification with null scores and empty transcription")
    func decoderAcceptsDroppedVerificationWithNullScores() throws {
        let decoded = try #require(
            WhisperTranscriptDecoder.decodeRichJSON(droppedWindowRichJSON()),
            "null verification scores must be ignored rather than rejecting the payload"
        )
        #expect(decoded.text.isEmpty)
        #expect(decoded.segments.isEmpty)
        #expect(decoded.avgConfidence == nil)
        #expect(decoded.durationMS == 0)
    }

    @Test("Replaced-window rich JSON reaches insertion and history exactly once")
    func replacedWindowRichJSONReachesSinksExactlyOnce() async throws {
        let payload = replacedWindowRichJSON(includeVerification: true)
        let expectedRaw = try #require(WhisperTranscriptDecoder.decodeRichJSON(payload))
        assertReplacedWindowTranscript(expectedRaw)

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-verification-rich-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let audioURL = scratch.appendingPathComponent("capture.wav")
        try Data().write(to: audioURL)
        let historyURL = scratch.appendingPathComponent("history.json")
        let observation = VerificationPipelineObservation()
        let appContext = AppContext(
            bundleIdentifier: "com.example.verification-rich-output",
            appName: "Fixture Editor"
        )
        let lexiconService = PersonalLexiconService(entries: [])
        let styleProfileService = StyleProfileService()
        let engine = RetainedWhisperTranscriptionEngine(
            configuration: RetainedWhisperTranscriptionConfiguration(
                helperExecutableURL: URL(fileURLWithPath: "/tmp/steno-verification-helper"),
                modelPath: URL(fileURLWithPath: "/tmp/steno-verification-model.bin"),
                threadCount: 1,
                vadModelPath: nil,
                suppressNonSpeechTokens: true,
                suppressRegex: nil
            ),
            sessionFactory: VerificationJSONSessionFactory(payload: payload),
            fallback: UnexpectedRetainedFallback()
        )
        let history = HistoryStore(storageURL: historyURL, clipboardService: MemoryClipboardService())
        let coordinator = SessionCoordinator(
            captureService: StubAudioCaptureService(queuedAudioURLs: [audioURL]),
            transcriptionEngine: engine,
            cleanupEngine: ObservingCleanupEngine(observation: observation),
            insertionService: InsertionService(
                transports: [
                    ClosureInsertionTransport(method: .direct) { text, _ in
                        await observation.recordInsert(text)
                    }
                ]
            ),
            historyStore: history,
            lexiconService: lexiconService,
            styleProfileService: styleProfileService,
            snippetService: SnippetService(snippets: []),
            editorTargetCapture: { _ in .failure(.unsupportedElement) }
        )

        do {
            let expectedClean = try await RuleBasedCleanupEngine().cleanup(
                raw: expectedRaw,
                profile: await styleProfileService.resolve(for: appContext),
                lexicon: await lexiconService.snapshot(for: appContext)
            )

            let sessionID = try await coordinator.startPressToTalk(
                appContext: appContext,
                options: .init(livePreviewEnabled: false, nearbyContextEnabled: false)
            )
            try await coordinator.endPressToTalkCapture(sessionID: sessionID)
            let result = try await coordinator.completePressToTalk(sessionID: sessionID)

            #expect(result.status == .inserted)
            #expect(result.insertedText == expectedClean.text)

            let inserted = await observation.insertedTexts()
            #expect(inserted == [expectedClean.text])

            let forwarded = try #require(await observation.rawTranscripts().first)
            #expect(await observation.rawTranscripts().count == 1)
            #expect(forwarded == expectedRaw)
            #expect(forwarded.segments == expectedRaw.segments)
            #expect(forwarded.avgConfidence == expectedRaw.avgConfidence)
            #expect(forwarded.durationMS == expectedRaw.durationMS)

            let liveEntries = await history.recent(limit: 10)
            #expect(liveEntries.count == 1)
            #expect(liveEntries.first?.rawText == expectedRaw.text)
            #expect(liveEntries.first?.cleanText == expectedClean.text)
            #expect(liveEntries.first?.durationMS == expectedRaw.durationMS)
            #expect(liveEntries.first?.insertionStatus == .inserted)

            await #expect(throws: SessionCoordinatorError.sessionNotFound) {
                _ = try await coordinator.completePressToTalk(sessionID: sessionID)
            }
            #expect(await observation.insertedTexts().count == 1)
            #expect(await history.recent(limit: 10).count == 1)

            let reloaded = HistoryStore(storageURL: historyURL, clipboardService: MemoryClipboardService())
            let persisted = await reloaded.recent(limit: 10)
            #expect(persisted.count == 1)
            #expect(persisted.first?.rawText == expectedRaw.text)
            #expect(persisted.first?.cleanText == expectedClean.text)
            #expect(persisted.first?.durationMS == expectedRaw.durationMS)

            await coordinator.shutdown()
        } catch {
            await coordinator.shutdown()
            throw error
        }
    }
}

private func assertReplacedWindowTranscript(_ transcript: RawTranscript) {
    let expectedConfidence = replacedWindowTokenProbabilities.reduce(0, +)
        / Double(replacedWindowTokenProbabilities.count)
    #expect(transcript.text == "please send the document before the meeting tomorrow.")
    #expect(transcript.durationMS == 4_320)
    #expect(transcript.segments.count == 1)
    #expect(transcript.segments[0].text == "please send the document before the meeting tomorrow.")
    #expect(transcript.segments[0].startMS == 0)
    #expect(transcript.segments[0].endMS == 4_320)
    #expect(abs((transcript.segments[0].confidence ?? .nan) - expectedConfidence) < 0.0001)
    #expect(abs((transcript.avgConfidence ?? .nan) - expectedConfidence) < 0.0001)
}

private let replacedWindowTokenProbabilities: [Double] = [
    0.92, 0.88, 0.97, 0.91, 0.86, 0.95, 0.89, 0.84, 0.78,
]

private func replacedWindowRichJSON(includeVerification: Bool) -> Data {
    var json = """
    {
      "transcription": [
        {
          "offsets": { "from": 0, "to": 4320 },
          "text": " please send the document before the meeting tomorrow.",
          "tokens": [
            { "text": " please", "offsets": { "from": 0, "to": 480 }, "id": 1, "p": 0.92 },
            { "text": " send", "offsets": { "from": 480, "to": 840 }, "id": 2, "p": 0.88 },
            { "text": " the", "offsets": { "from": 840, "to": 1080 }, "id": 3, "p": 0.97 },
            { "text": " document", "offsets": { "from": 1080, "to": 1680 }, "id": 4, "p": 0.91 },
            { "text": " before", "offsets": { "from": 1680, "to": 2160 }, "id": 5, "p": 0.86 },
            { "text": " the", "offsets": { "from": 2160, "to": 2400 }, "id": 6, "p": 0.95 },
            { "text": " meeting", "offsets": { "from": 2400, "to": 2880 }, "id": 7, "p": 0.89 },
            { "text": " tomorrow", "offsets": { "from": 2880, "to": 3600 }, "id": 8, "p": 0.84 },
            { "text": ".", "offsets": { "from": 3600, "to": 4320 }, "id": 9, "p": 0.78 }
          ]
        }
      ]
    """
    if includeVerification {
        json += """
        ,
          "verification": {
            "triggered": true,
            "windows": [
              {
                "seek": 0,
                "decision": "replaced",
                "tier": 0,
                "wordsP": 4,
                "wordsN": 18,
                "P": {
                  "words": 4,
                  "otherTokens": 2,
                  "otherSupport": -0.196944,
                  "suspect": [
                    { "word": "terms", "group": "label", "occurrences": 2, "first": -2.19816 }
                  ]
                },
                "V": null,
                "N": { "words": 23, "otherTokens": 24, "otherSupport": 3.96144, "suspect": [] }
              }
            ]
          }
        """
    }
    json += "\n}"
    return Data(json.utf8)
}

private func droppedWindowRichJSON() -> Data {
    Data(
        """
        {
          "transcription": [],
          "verification": {
            "triggered": true,
            "windows": [
              {
                "seek": 0,
                "decision": "dropped",
                "tier": 0,
                "wordsP": 4,
                "wordsN": 1,
                "P": {
                  "words": 4,
                  "otherTokens": 0,
                  "otherSupport": null,
                  "suspect": [
                    { "word": "terms", "group": "label", "occurrences": 4, "first": -1.80607 }
                  ]
                },
                "V": null,
                "N": { "words": 1, "otherTokens": 1, "otherSupport": 5.44948, "suspect": [] }
              }
            ]
          }
        }
        """.utf8
    )
}

private actor VerificationPipelineObservation {
    private var raws: [RawTranscript] = []
    private var inserted: [String] = []

    func recordRaw(_ raw: RawTranscript) {
        raws.append(raw)
    }

    func recordInsert(_ text: String) {
        inserted.append(text)
    }

    func rawTranscripts() -> [RawTranscript] {
        raws
    }

    func insertedTexts() -> [String] {
        inserted
    }
}

private struct ObservingCleanupEngine: CleanupEngine {
    let observation: VerificationPipelineObservation

    func cleanup(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> CleanTranscript {
        await observation.recordRaw(raw)
        return try await RuleBasedCleanupEngine().cleanup(raw: raw, profile: profile, lexicon: lexicon)
    }
}

private struct VerificationJSONSessionFactory: WhisperRuntimeSessionFactory {
    let payload: Data

    func makeSession(
        configuration: RetainedWhisperTranscriptionConfiguration
    ) async throws -> any WhisperRuntimeSession {
        _ = configuration
        return VerificationJSONRuntimeSession(payload: payload)
    }
}

private struct VerificationJSONRuntimeSession: WhisperRuntimeSession {
    let payload: Data

    func transcribe(_ request: WhisperRuntimeRequest) async throws -> Data {
        _ = request
        return payload
    }

    func shutdown() async {}
}

private struct UnexpectedRetainedFallback: TranscriptionEngine {
    struct FallbackWasUsed: Error {}

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        _ = audioURL
        _ = request
        throw FallbackWasUsed()
    }
}
