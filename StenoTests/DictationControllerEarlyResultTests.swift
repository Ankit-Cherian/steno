import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

@Suite("Result shown as soon as the text is delivered", .serialized)
@MainActor
struct DictationControllerEarlyResultTests {
    @Test("The result shows while the usage ledger is still being written, and only once")
    func resultShowsBeforePersistenceFinishes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoEarlyResult-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = TranscriptionCancelCapture(directory: directory)
        let transport = TranscriptionCancelTransport()
        let history = HistoryStore(storageURL: directory.appendingPathComponent("history.json"))
        let usage = RecordGatedUsageStore(base: UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json")))
        let coordinator = SessionCoordinator(
            captureService: capture,
            transcriptionEngine: FixedTextEngine(),
            cleanupEngine: RuleBasedCleanupEngine(),
            insertionService: InsertionService(transports: [transport]),
            historyStore: history,
            lexiconService: PersonalLexiconService(entries: []),
            styleProfileService: StyleProfileService(),
            usageRecorder: usage,
            editorTargetCapture: { _ in .failure(.unsupportedElement) }
        )
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.hostedEvidencePrepareOffscreen()
        let controller = makeTestDictationController(
            hotkey: TranscriptionCancelHotkey(),
            overlay: presenter,
            preferencesStore: AppPreferencesStore(storageURL: directory.appendingPathComponent("preferences.json")),
            coordinator: coordinator,
            historyStore: history,
            usageAnalyticsStore: usage,
            legacyHistoryURL: directory.appendingPathComponent("legacy.json")
        )

        func insertedResults() -> Int {
            presenter.hostedEvidenceRequestedStates().filter { state in
                if case .result(.inserted, _) = state { return true }
                return false
            }.count
        }

        controller.pressToTalkStart()
        try #require(await cancelTestEventually { await capture.startedCount() == 1 })
        controller.pressToTalkStop()
        try #require(await cancelTestEventually { await usage.waitingRecords > 0 },
                     "the usage write never started")

        // Inserted and saved to History; the usage write is held open.
        #expect(await transport.texts() == ["First dictation."])
        #expect(await history.recent(limit: 5).count == 1)
        #expect(insertedResults() == 1)
        #expect(controller.recordingLifecycleState == .transcribing)

        await usage.openRecords()
        try #require(await cancelTestEventually { @MainActor in controller.recordingLifecycleState == .idle })
        #expect(insertedResults() == 1)
        #expect(controller.lastTranscript == "First dictation.")
        controller.teardown()
        await coordinator.shutdown()
    }

    @Test("Nothing recognized as speech still shows its result after the completion returns")
    func noSpeechIsShownOnReturn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoEarlyResult-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = TranscriptionCancelCapture(directory: directory)
        let history = HistoryStore(storageURL: directory.appendingPathComponent("history.json"))
        let coordinator = SessionCoordinator(
            captureService: capture,
            transcriptionEngine: StaticSilenceEngine(),
            cleanupEngine: RuleBasedCleanupEngine(),
            insertionService: InsertionService(transports: [TranscriptionCancelTransport()]),
            historyStore: history,
            lexiconService: PersonalLexiconService(entries: []),
            styleProfileService: StyleProfileService(),
            editorTargetCapture: { _ in .failure(.unsupportedElement) }
        )
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.hostedEvidencePrepareOffscreen()
        let controller = makeTestDictationController(
            hotkey: TranscriptionCancelHotkey(),
            overlay: presenter,
            coordinator: coordinator,
            historyStore: history,
            legacyHistoryURL: directory.appendingPathComponent("legacy.json")
        )

        controller.pressToTalkStart()
        try #require(await cancelTestEventually { await capture.startedCount() == 1 })
        controller.pressToTalkStop()
        try #require(await cancelTestEventually { @MainActor in controller.recordingLifecycleState == .idle })
        #expect(presenter.hostedEvidenceRequestedStates().filter { $0 == .noSpeechDetected }.count == 1)
        #expect(await history.recent(limit: 5).isEmpty)
        controller.teardown()
        await coordinator.shutdown()
    }
}

private struct StaticSilenceEngine: TranscriptionEngine {
    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        RawTranscript(text: " . ")
    }
}

/// Holds each usage write open until released, like a slow disk.
actor RecordGatedUsageStore: UsageAnalyticsStoreServicing {
    private let base: UsageAnalyticsStore
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waitingRecords = 0

    init(base: UsageAnalyticsStore) {
        self.base = base
    }

    func openRecords() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func record(event: UsageEvent) async throws {
        if !isOpen {
            waitingRecords += 1
            await withCheckedContinuation { waiters.append($0) }
        }
        try await base.record(event: event)
    }

    func recoverCorruptArchiveIfNeeded() async throws -> URL? {
        try await base.recoverCorruptArchiveIfNeeded()
    }

    func reconcileHistory(legacyURL: URL?, currentEntries: [TranscriptEntry]) async throws -> String? {
        try await base.reconcileHistory(legacyURL: legacyURL, currentEntries: currentEntries)
    }

    func snapshot(now: Date, calendar: Calendar, months: Int) async throws -> UsageAnalyticsSnapshot {
        try await base.snapshot(now: now, calendar: calendar, months: months)
    }
}

