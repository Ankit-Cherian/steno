import Foundation
import Testing
import StenoKitTestSupport
@testable import StenoKit

private actor DeliveryCounter {
    private(set) var deliveries: [String] = []
    func record(_ text: String) { deliveries.append(text) }
}

private actor RecordedUsageEvents: UsageAnalyticsRecording {
    private(set) var count = 0
    func record(event: UsageEvent) async throws { count += 1 }
}

@Suite("History write failure after insertion", .serialized)
struct SessionCoordinatorHistoryFailureTests {
    /// A real History store whose folder can't be written, as after a disk or
    /// permission problem.
    private func unwritableHistory() throws -> (HistoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-unwritable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        let store = HistoryStore(
            storageURL: directory.appendingPathComponent("transcript-history.json"),
            clipboardService: MemoryClipboardService()
        )
        return (store, directory)
    }

    private func removeUnwritable(_ directory: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("A delivered transcript stays inserted, is delivered once, and keeps its text")
    func deliveredTranscriptIsNotReportedAsFailed() async throws {
        let (history, directory) = try unwritableHistory()
        defer { removeUnwritable(directory) }
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-\(UUID().uuidString).wav")
        try Data().write(to: audioURL)
        let deliveries = DeliveryCounter()
        let usage = RecordedUsageEvents()

        let coordinator = SessionCoordinator(
            captureService: StubAudioCaptureService(queuedAudioURLs: [audioURL]),
            transcriptionEngine: StaticTranscriptionEngine { _, _ in
                RawTranscript(text: "meeting notes are ready", avgConfidence: 0.93)
            },
            cleanupEngine: RuleBasedCleanupEngine(),
            insertionService: InsertionService(transports: [
                ClosureInsertionTransport(method: .direct) { text, _ in
                    await deliveries.record(text)
                }
            ]),
            historyStore: history,
            lexiconService: PersonalLexiconService(),
            styleProfileService: StyleProfileService(),
            usageRecorder: usage
        )

        let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
        let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

        #expect(result.status == .inserted)
        #expect(result.insertedText == "Meeting notes are ready")
        #expect(await deliveries.deliveries == ["Meeting notes are ready"])
        #expect(result.historyWarning != nil)
        #expect(await usage.count == 1)
        #expect(await history.recent(limit: 10).isEmpty)
    }

    @Test("A transcript whose insertion failed is still returned when History can't be written")
    func failedInsertionStillReturnsText() async throws {
        let (history, directory) = try unwritableHistory()
        defer { removeUnwritable(directory) }
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-\(UUID().uuidString).wav")
        try Data().write(to: audioURL)

        let coordinator = SessionCoordinator(
            captureService: StubAudioCaptureService(queuedAudioURLs: [audioURL]),
            transcriptionEngine: StaticTranscriptionEngine { _, _ in
                RawTranscript(text: "keep this text", avgConfidence: 0.93)
            },
            cleanupEngine: RuleBasedCleanupEngine(),
            insertionService: InsertionService(transports: []),
            historyStore: history,
            lexiconService: PersonalLexiconService(),
            styleProfileService: StyleProfileService()
        )

        let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
        let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

        #expect(result.status == .failed)
        #expect(result.insertedText == "Keep this text")
        #expect(result.historyWarning != nil)
    }
}
