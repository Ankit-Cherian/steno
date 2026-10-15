import Foundation
import Testing
import StenoKitTestSupport
@testable import StenoKit

@Suite("Steps a dictation reports after Stop")
struct SessionCoordinatorStepTests {
    private func runDictation(
        text: String,
        steps: StepRecorder,
        whenDelivered: (@Sendable (InsertResult) -> Void)? = nil
    ) async throws -> InsertResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("audio.wav")
        try Data().write(to: audioURL)
        let coordinator = SessionCoordinator(
            captureService: StubAudioCaptureService(queuedAudioURLs: [audioURL]),
            transcriptionEngine: StaticTranscriptionEngine { _, _ in RawTranscript(text: text, durationMS: 1_000) },
            cleanupEngine: RuleBasedCleanupEngine(),
            insertionService: InsertionService(transports: [
                ClosureInsertionTransport(method: .direct) { _, _ in },
            ]),
            historyStore: HistoryStore(
                storageURL: directory.appendingPathComponent("history.json")
            ),
            lexiconService: PersonalLexiconService(),
            styleProfileService: StyleProfileService(),
            usageRecorder: UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json")),
            editorTargetCapture: { _ in .failure(.unsupportedElement) },
            stepObserver: { steps.record($0) }
        )
        let sessionID = try await coordinator.startPressToTalk(
            appContext: AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
        )
        try await coordinator.endPressToTalkCapture(sessionID: sessionID)
        return try await coordinator.completePressToTalk(
            sessionID: sessionID,
            copyingBecause: nil,
            whenDelivered: whenDelivered
        )
    }

    @Test("A dictation reports each step once, in the order it happens")
    func everyStepInOrder() async throws {
        let steps = StepRecorder()
        let result = try await runDictation(text: "the meeting is at noon", steps: steps)

        #expect(result.status == .inserted)
        #expect(steps.all == [
            .captureClosed, .transcriptionStarted, .transcribed, .cleanedUp,
            .inserted, .historySaved, .usageRecorded,
        ])
    }

    @Test("A recording with no speech stops reporting once it is transcribed")
    func noSpeechStopsAfterTranscription() async throws {
        let steps = StepRecorder()
        let result = try await runDictation(text: " . ", steps: steps)

        #expect(result.status == .noSpeech)
        #expect(steps.all == [.captureClosed, .transcriptionStarted, .transcribed])
    }

    @Test("The delivered result arrives once, after insertion and before History is written")
    func deliveredBeforePersistence() async throws {
        let steps = StepRecorder()
        let delivered = DeliveryRecorder()
        let result = try await runDictation(text: "the meeting is at noon", steps: steps) { result in
            delivered.record(result, after: steps.all)
        }

        let deliveries = delivered.all
        #expect(deliveries.count == 1)
        #expect(deliveries.first?.result.status == .inserted)
        #expect(deliveries.first?.result.insertedText == result.insertedText)
        #expect(deliveries.first?.stepsBefore.last == .inserted)
    }

    @Test("Nothing is delivered early when nothing was recognized as speech")
    func noSpeechIsNotDelivered() async throws {
        let delivered = DeliveryRecorder()
        let result = try await runDictation(text: " . ", steps: StepRecorder()) { result in
            delivered.record(result, after: [])
        }

        #expect(result.status == .noSpeech)
        #expect(delivered.all.isEmpty)
    }
}

private final class DeliveryRecorder: @unchecked Sendable {
    struct Delivery { var result: InsertResult; var stepsBefore: [DictationStep] }
    private let lock = NSLock()
    private var deliveries: [Delivery] = []

    func record(_ result: InsertResult, after steps: [DictationStep]) {
        lock.withLock { deliveries.append(Delivery(result: result, stepsBefore: steps)) }
    }
    var all: [Delivery] { lock.withLock { deliveries } }
}
