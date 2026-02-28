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

@Test("SessionCoordinator marks localSuccess when primary cleanup succeeds")
func sessionCoordinatorLocalSuccessOutcome() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let capture = StubAudioCaptureService(queuedAudioURLs: [audioURL])
    let transcription = StaticTranscriptionEngine { _, _ in
        RawTranscript(text: "local success test")
    }

    let cleanupCounter = CleanupCounter()
    let cleanupEngine = CountingCleanupEngine(counter: cleanupCounter)

    let recorder = InsertRecorder()
    let insertionService = InsertionService(
        transports: [
            ClosureInsertionTransport(method: .direct) { text, _ in
                await recorder.record(text)
            }
        ]
    )

    let historyURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("history-tests", isDirectory: true)
        .appendingPathComponent("history-\(UUID().uuidString).json")
    let history = HistoryStore(storageURL: historyURL, clipboardService: MemoryClipboardService())

    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: transcription,
        cleanupEngine: cleanupEngine,
        insertionService: insertionService,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService()
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.status == .inserted)
    #expect(result.cleanupOutcome?.source == .localSuccess)
    #expect(result.cleanupOutcome?.warning == nil)
    #expect(await cleanupCounter.value() == 1)

    let inserted = await recorder.latest() ?? ""
    #expect(inserted == "local success test cleaned")
}

@Test("SessionCoordinator falls back locally when primary cleanup fails")
func sessionCoordinatorLocalFallbackOnPrimaryFailure() async throws {
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

    let historyURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("history-tests", isDirectory: true)
        .appendingPathComponent("history-\(UUID().uuidString).json")
    let history = HistoryStore(storageURL: historyURL, clipboardService: MemoryClipboardService())

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
        fallbackCleanupEngine: RuleBasedCleanupEngine()
    )

    let sessionID = try await coordinator.startPressToTalk(appContext: AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes"))
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.status == .inserted)
    #expect(result.cleanupOutcome?.source == .localFallback)
    #expect(result.cleanupOutcome?.warning == "Primary cleanup unavailable, used local fallback.")

    let inserted = await recorder.latest() ?? ""
    #expect(inserted.contains("Steno"))
    #expect(!inserted.localizedCaseInsensitiveContains("um "))

    let recent = await history.recent(limit: 1)
    #expect(recent.count == 1)
    #expect(recent[0].cleanText == inserted)
    #expect(recent[0].audioURL == nil)
}

@Test("SessionCoordinator keeps slash commands raw for IDE passthrough profile")
func sessionCoordinatorCommandPassthroughStaysLocalOnly() async throws {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)

    let capture = StubAudioCaptureService(queuedAudioURLs: [audioURL])
    let transcription = StaticTranscriptionEngine { _, _ in
        RawTranscript(text: "/build target")
    }

    let recorder = InsertRecorder()
    let insertionService = InsertionService(
        transports: [
            ClosureInsertionTransport(method: .direct) { text, _ in
                await recorder.record(text)
            }
        ]
    )

    let style = StyleProfile(
        name: "IDE",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .minimal,
        commandPolicy: .passthrough
    )

    let historyURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("history-tests", isDirectory: true)
        .appendingPathComponent("history-\(UUID().uuidString).json")
    let history = HistoryStore(storageURL: historyURL, clipboardService: MemoryClipboardService())

    let coordinator = SessionCoordinator(
        captureService: capture,
        transcriptionEngine: transcription,
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: insertionService,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(globalProfile: style)
    )

    let ideContext = AppContext(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode", isIDE: true)
    let sessionID = try await coordinator.startPressToTalk(appContext: ideContext)
    let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

    #expect(result.status == .inserted)
    #expect(result.cleanupOutcome?.source == .localOnly)

    let inserted = await recorder.latest() ?? ""
    #expect(inserted == "/build target")
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
        styleProfileService: StyleProfileService()
    )

    #expect(await coordinator.isHandsFreeEnabled == false)
    await coordinator.setHandsFreeEnabled(true)
    #expect(await coordinator.isHandsFreeEnabled == true)
    await coordinator.setHandsFreeEnabled(false)
    #expect(await coordinator.isHandsFreeEnabled == false)
}
