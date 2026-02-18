import Foundation
import Testing
@testable import StenoKit

private actor InsertRecorder {
    private var inserts: [String] = []

    func record(_ text: String) {
        inserts.append(text)
    }

    func latest() -> String? {
        inserts.last
    }
}

@Test("SessionCoordinator falls back to local cleanup when cloud cleanup fails")
func sessionCoordinatorFallbackOnCloudFailure() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let capture = StubAudioCaptureService(queuedAudioURLs: [audioURL])
    let transcription = StaticTranscriptionEngine { _, _ in
        RawTranscript(text: "um stenoh can you clean this up")
    }

    let recorder = InsertRecorder()
    let insertionService = InsertionService(
        transports: [
            ClosureInsertionTransport(method: .direct) { text, _ in
                await recorder.record(text)
            }
        ]
    )

    let clipboard = MemoryClipboardService()
    let historyURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("history-tests", isDirectory: true)
        .appendingPathComponent("history-\(UUID().uuidString).json")
    let history = HistoryStore(storageURL: historyURL, clipboardService: clipboard)

    let lexicon = PersonalLexiconService()
    await lexicon.upsert(term: "stenoh", preferred: "Steno", scope: .global)

    let styles = StyleProfileService(
        globalProfile: StyleProfile(
            name: "Default",
            tone: .natural,
            structureMode: .paragraph,
            fillerPolicy: .balanced,
            commandPolicy: .transform
        )
    )

    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: transcription,
        cleanupEngine: FailingCleanupEngine(),
        insertionService: insertionService,
        historyStore: history,
        lexiconService: lexicon,
        styleProfileService: styles,
        budgetGuard: BudgetGuard(startingSpendUSD: 0),
        fallbackCleanupEngine: RuleBasedCleanupEngine()
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes"))
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.status == .inserted)

    let inserted = await recorder.latest() ?? ""
    #expect(inserted.contains("Steno"))
    #expect(!inserted.localizedCaseInsensitiveContains("um "))

    let recent = await history.recent(limit: 1)
    #expect(recent.count == 1)
    #expect(recent[0].cleanText == inserted)
    #expect(recent[0].audioURL == nil)
}

@Test("SessionCoordinator skips cloud cleanup when budget hard cap is reached")
func sessionCoordinatorRespectsBudgetHardCap() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let capture = StubAudioCaptureService(queuedAudioURLs: [audioURL])
    let transcription = StaticTranscriptionEngine { _, _ in
        RawTranscript(text: "uh this should stay local")
    }

    let recorder = InsertRecorder()
    let insertionService = InsertionService(
        transports: [
            ClosureInsertionTransport(method: .direct) { text, _ in
                await recorder.record(text)
            }
        ]
    )

    let clipboard = MemoryClipboardService()
    let historyURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("history-tests", isDirectory: true)
        .appendingPathComponent("history-\(UUID().uuidString).json")
    let history = HistoryStore(storageURL: historyURL, clipboardService: clipboard)

    let lexicon = PersonalLexiconService()
    let styles = StyleProfileService()

    let cleanupCounter = CleanupCounter()
    let countingCleanup = CountingCleanupEngine(counter: cleanupCounter)

    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: transcription,
        cleanupEngine: countingCleanup,
        insertionService: insertionService,
        historyStore: history,
        lexiconService: lexicon,
        styleProfileService: styles,
        budgetGuard: BudgetGuard(startingSpendUSD: Decimal(string: "8.00")!),
        fallbackCleanupEngine: RuleBasedCleanupEngine()
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.status == .inserted)
    #expect(await cleanupCounter.value() == 0)

    let inserted = await recorder.latest() ?? ""
    #expect(!inserted.localizedCaseInsensitiveContains("uh "))

    let recent = await history.recent(limit: 1)
    #expect(recent.count == 1)
    #expect(recent[0].audioURL == nil)
}

@Test("SessionCoordinator hands-free state uses explicit setter")
func sessionCoordinatorExplicitHandsFreeSetter() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let coordinator = SessionCoordinator(
        captureService: StubAudioCaptureService(queuedAudioURLs: [audioURL]),
        transcriptionEngine: StaticTranscriptionEngine { _, _ in RawTranscript(text: "test") },
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: InsertionService(transports: []),
        historyStore: HistoryStore(
            storageURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("history-tests", isDirectory: true)
                .appendingPathComponent("history-\(UUID().uuidString).json"),
            clipboardService: MemoryClipboardService()
        ),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        budgetGuard: BudgetGuard()
    )

    #expect(await coordinator.isHandsFreeEnabled == false)
    await coordinator.setHandsFreeEnabled(true)
    #expect(await coordinator.isHandsFreeEnabled == true)
    await coordinator.setHandsFreeEnabled(false)
    #expect(await coordinator.isHandsFreeEnabled == false)
}
