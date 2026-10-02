import Foundation
import Testing
import StenoKitTestSupport
@testable import StenoKit

@Test("A capture that stopped early is still transcribed and inserted, with the microphone message")
func interruptedCaptureIsTranscribedWithMessage() async throws {
    let interruption = CaptureInterruption(reason: .recorderStopped, deviceName: "USB Desk Mic")
    let fixture = try InterruptedCaptureFixture(transcript: "Send the report by Friday", interruption: interruption)

    let sessionID = try await fixture.coordinator.startPressToTalk(appContext: .unknown)
    let result = try await fixture.coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(await fixture.transcribedURLs.value == [fixture.audioURL])
    #expect(result.status == .inserted)
    #expect(result.insertedText == "Send the report by Friday")
    #expect(await fixture.inserted.texts() == ["Send the report by Friday"])
    #expect(result.captureWarning == interruption.message)
    #expect(result.captureWarning?.contains("microphone “USB Desk Mic” stopped") == true)
    #expect(await fixture.history.recent(limit: 10).count == 1)
}

@Test("A capture that stopped early with nothing recognized reports the microphone, not only no speech")
func interruptedCaptureWithoutSpeechCarriesMessage() async throws {
    let interruption = CaptureInterruption(reason: .recordingShorterThanElapsed)
    let fixture = try InterruptedCaptureFixture(transcript: "", interruption: interruption)

    let sessionID = try await fixture.coordinator.startPressToTalk(appContext: .unknown)
    let result = try await fixture.coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.status == .noSpeech)
    #expect(result.captureWarning == interruption.message)
    #expect(await fixture.inserted.texts().isEmpty)
    #expect(await fixture.history.recent(limit: 10).isEmpty)
}

@Test("A complete capture carries no microphone message")
func completeCaptureCarriesNoMessage() async throws {
    let fixture = try InterruptedCaptureFixture(transcript: "All good", interruption: nil)

    let sessionID = try await fixture.coordinator.startPressToTalk(appContext: .unknown)
    let result = try await fixture.coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.status == .inserted)
    #expect(result.captureWarning == nil)
}

private struct InterruptedCaptureFixture {
    let audioURL: URL
    let coordinator: SessionCoordinator
    let history: HistoryStore
    let inserted = InsertedTextLog()
    let transcribedURLs = URLLog()

    init(transcript: String, interruption: CaptureInterruption?) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CaptureInterruption-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        audioURL = directory.appendingPathComponent("audio.wav")
        try Data().write(to: audioURL)

        let transcribedURLs = self.transcribedURLs
        let transcription = StaticTranscriptionEngine { url, _ in
            await transcribedURLs.append(url)
            return RawTranscript(text: transcript, avgConfidence: 0.93)
        }
        let inserted = self.inserted
        history = HistoryStore(
            storageURL: directory.appendingPathComponent("history.json"),
            clipboardService: MemoryClipboardService()
        )
        coordinator = SessionCoordinator(
            captureService: InterruptingCaptureService(audioURL: audioURL, interruption: interruption),
            transcriptionEngine: transcription,
            cleanupEngine: RuleBasedCleanupEngine(),
            insertionService: InsertionService(transports: [
                ClosureInsertionTransport(method: .direct) { text, _ in
                    await inserted.record(text)
                }
            ]),
            historyStore: history,
            lexiconService: PersonalLexiconService(),
            styleProfileService: StyleProfileService()
        )
    }
}

private actor InterruptingCaptureService: AudioCaptureService {
    private let audioURL: URL
    private var interruption: CaptureInterruption?
    private var ended = false

    init(audioURL: URL, interruption: CaptureInterruption?) {
        self.audioURL = audioURL
        self.interruption = interruption
    }

    func beginCapture(sessionID: SessionID) async throws {}

    func endCapture(sessionID: SessionID) async throws -> URL {
        ended = true
        return audioURL
    }

    func cancelCapture(sessionID: SessionID) async {}

    func takeCaptureInterruption(sessionID: SessionID) async -> CaptureInterruption? {
        guard ended else { return nil }
        defer { interruption = nil }
        return interruption
    }
}

private actor InsertedTextLog {
    private var values: [String] = []

    func record(_ text: String) {
        values.append(text)
    }

    func texts() -> [String] {
        values
    }
}

private actor URLLog {
    private(set) var value: [URL] = []

    func append(_ url: URL) {
        value.append(url)
    }
}
