import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

@Suite(.serialized)
@MainActor
struct DictationControllerCompletionTests {
    @Test("A press right after insertion starts recording while Insights is still refreshing")
    func pressDuringPostInsertionRefreshStartsCapture() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoCompletion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = TranscriptionCancelCapture(directory: directory)
        let transport = TranscriptionCancelTransport()
        let clipboard = MemoryClipboardService()
        let history = HistoryStore(storageURL: directory.appendingPathComponent("history.json"), clipboardService: clipboard)
        let analytics = GatedUsageAnalyticsStore(
            base: UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json"))
        )
        let coordinator = SessionCoordinator(
            captureService: capture,
            transcriptionEngine: FixedTextEngine(),
            cleanupEngine: RuleBasedCleanupEngine(),
            insertionService: InsertionService(transports: [transport]),
            historyStore: history,
            lexiconService: PersonalLexiconService(entries: []),
            styleProfileService: StyleProfileService(),
            usageRecorder: analytics,
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
            usageAnalyticsStore: analytics,
            legacyHistoryURL: directory.appendingPathComponent("legacy.json")
        )

        await analytics.closeSnapshots()
        controller.pressToTalkStart()
        try #require(await cancelTestEventually { await capture.startedCount() == 1 })
        controller.pressToTalkStop()
        try #require(await cancelTestEventually { await transport.texts().count == 1 })
        try #require(await cancelTestEventually { await analytics.waitingSnapshots > 0 },
                     "Insights refresh never started")

        // Insights is still refreshing. The dictation itself is complete.
        #expect(controller.recordingLifecycleState == .idle)
        controller.pressToTalkStart()
        #expect(await cancelTestEventually { await capture.startedCount() == 2 })
        #expect(controller.recordingLifecycleState == .recordingPressToTalk)

        await analytics.openSnapshots()
        controller.pressToTalkStop()
        #expect(await cancelTestEventually { await transport.texts().count == 2 })
        controller.teardown()
        await coordinator.shutdown()
    }
}

struct FixedTextEngine: TranscriptionEngine {
    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        RawTranscript(text: "First dictation.")
    }
}

/// Holds Insights snapshots open until released, like a slow refresh.
actor GatedUsageAnalyticsStore: UsageAnalyticsStoreServicing {
    private let base: UsageAnalyticsStore
    private var isClosed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waitingSnapshots = 0

    init(base: UsageAnalyticsStore) {
        self.base = base
    }

    func closeSnapshots() { isClosed = true }

    func openSnapshots() {
        isClosed = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func record(event: UsageEvent) async throws {
        try await base.record(event: event)
    }

    func recoverCorruptArchiveIfNeeded() async throws -> URL? {
        try await base.recoverCorruptArchiveIfNeeded()
    }

    func reconcileHistory(legacyURL: URL?, currentEntries: [TranscriptEntry]) async throws -> String? {
        try await base.reconcileHistory(legacyURL: legacyURL, currentEntries: currentEntries)
    }

    func snapshot(now: Date, calendar: Calendar, months: Int) async throws -> UsageAnalyticsSnapshot {
        if isClosed {
            waitingSnapshots += 1
            await withCheckedContinuation { waiters.append($0) }
        }
        return try await base.snapshot(now: now, calendar: calendar, months: months)
    }
}
