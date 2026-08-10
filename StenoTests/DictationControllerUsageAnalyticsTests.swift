import Foundation
import Testing
@testable import Steno
import StenoKit

@MainActor
@Test("Insights refresh backfills current and legacy history without filling the unknown gap")
func insightsRefreshBackfillsAllRecoverableHistory() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoInsightsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let currentHistory = HistoryStore(
        storageURL: directory.appendingPathComponent("current-history.json"),
        clipboardService: MemoryClipboardService()
    )
    try await currentHistory.append(
        entry: TranscriptEntry(
            createdAt: insightTestDate(2026, 6, 21),
            appBundleID: "com.example.Editor",
            rawText: "um current words",
            cleanText: "Current words.",
            durationMS: 12_000,
            audioURL: nil,
            insertionStatus: .copiedOnly
        )
    )

    let legacyURL = directory.appendingPathComponent("legacy-history.json")
    let legacyJSON = """
    [{
      "id": "30000000-0000-0000-0000-000000000001",
      "createdAt": "2026-02-11T19:57:29Z",
      "appBundleID": "dev.warp.Warp-Stable",
      "rawText": "um legacy words",
      "cleanText": "Legacy words.",
      "audioURL": null,
      "insertionStatus": "inserted"
    }]
    """
    try Data(legacyJSON.utf8).write(to: legacyURL, options: .atomic)

    let analyticsStore = UsageAnalyticsStore(
        storageURL: directory.appendingPathComponent("usage-analytics.json")
    )
    let controller = DictationController(
        hotkey: InsightsTestHotkeyService(),
        historyStore: currentHistory,
        usageAnalyticsStore: analyticsStore,
        legacyHistoryURL: legacyURL
    )
    defer { controller.teardown() }

    await controller.refreshUsageAnalytics(
        now: insightTestDate(2026, 7, 10),
        calendar: insightTestCalendar()
    )

    #expect(controller.usageAnalyticsError.isEmpty)
    #expect(controller.usageAnalyticsSnapshot.totalSessions == 2)
    #expect(controller.usageAnalyticsSnapshot.totalWords == 6)
    #expect(controller.usageAnalyticsSnapshot.coverage.count == 2)

    let gapDay = controller.usageAnalyticsSnapshot.dailyUsage.first {
        insightTestCalendar().isDate($0.date, inSameDayAs: insightTestDate(2026, 3, 1))
    }
    #expect(gapDay?.isTracked == false)

    await controller.refreshUsageAnalytics(
        now: insightTestDate(2026, 7, 10),
        calendar: insightTestCalendar()
    )
    #expect(controller.usageAnalyticsSnapshot.totalSessions == 2)
}

@MainActor
@Test("Unreadable legacy history warns while current Insights remain available")
func unreadableLegacyHistoryDoesNotBlockInsights() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoInsightsLegacyWarningTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let currentHistory = HistoryStore(
        storageURL: directory.appendingPathComponent("current-history.json"),
        clipboardService: MemoryClipboardService()
    )
    try await currentHistory.append(
        entry: TranscriptEntry(
            createdAt: insightTestDate(2026, 7, 9),
            appBundleID: "com.example.Editor",
            rawText: "current insights remain available",
            cleanText: "Current insights remain available.",
            durationMS: 8_000,
            audioURL: nil,
            insertionStatus: .inserted
        )
    )
    let legacyURL = directory.appendingPathComponent("legacy-history.json")
    try Data("malformed legacy history sentinel".utf8).write(
        to: legacyURL,
        options: .atomic
    )
    let controller = DictationController(
        hotkey: InsightsTestHotkeyService(),
        historyStore: currentHistory,
        usageAnalyticsStore: UsageAnalyticsStore(
            storageURL: directory.appendingPathComponent("usage-analytics.json")
        ),
        legacyHistoryURL: legacyURL
    )
    defer { controller.teardown() }

    await controller.refreshUsageAnalytics(
        now: insightTestDate(2026, 7, 10),
        calendar: insightTestCalendar()
    )

    #expect(controller.usageAnalyticsSnapshot.totalSessions == 1)
    #expect(controller.usageAnalyticsSnapshot.totalWords == 4)
    #expect(controller.usageAnalyticsError.contains("Older Steno history could not be imported"))
}

@MainActor
@Test("Current history wins when legacy migration contains the same session ID")
func currentHistoryWinsOverDuplicateLegacySession() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoInsightsOverlapTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sharedID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    let currentHistory = HistoryStore(
        storageURL: directory.appendingPathComponent("current-history.json"),
        clipboardService: MemoryClipboardService()
    )
    try await currentHistory.append(
        entry: TranscriptEntry(
            id: sharedID,
            createdAt: insightTestDate(2026, 6, 21),
            appBundleID: "com.apple.Notes",
            rawText: "new current words stay",
            cleanText: "New current words stay.",
            durationMS: 12_000,
            audioURL: nil,
            insertionStatus: .inserted
        )
    )

    let legacyURL = directory.appendingPathComponent("legacy-history.json")
    let legacyJSON = """
    [{
      "id": "\(sharedID.uuidString)",
      "createdAt": "2026-06-21T16:00:00Z",
      "appBundleID": "com.apple.Notes",
      "rawText": "stale",
      "cleanText": "Stale.",
      "durationMS": 1000,
      "audioURL": null,
      "insertionStatus": "copiedOnly"
    }]
    """
    try Data(legacyJSON.utf8).write(to: legacyURL, options: .atomic)

    let analyticsURL = directory.appendingPathComponent("usage-analytics.json")
    let controller = DictationController(
        hotkey: InsightsTestHotkeyService(),
        historyStore: currentHistory,
        usageAnalyticsStore: UsageAnalyticsStore(storageURL: analyticsURL),
        legacyHistoryURL: legacyURL
    )
    defer { controller.teardown() }

    for _ in 0..<2 {
        await controller.refreshUsageAnalytics(
            now: insightTestDate(2026, 7, 10),
            calendar: insightTestCalendar()
        )
    }

    let reloaded = UsageAnalyticsStore(storageURL: analyticsURL)
    let snapshot = try await reloaded.snapshot(
        now: insightTestDate(2026, 7, 10),
        calendar: insightTestCalendar(),
        months: 6
    )
    #expect(snapshot.totalSessions == 1)
    #expect(snapshot.totalWords == 4)
    #expect(snapshot.totalDurationMS == 12_000)
    #expect(snapshot.topApps.first?.sessionCount == 1)
}

@MainActor
@Test("Damaged analytics are preserved before recoverable history is rebuilt")
func corruptAnalyticsAreQuarantinedAndRebuilt() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoInsightsRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let currentHistory = HistoryStore(
        storageURL: directory.appendingPathComponent("current-history.json"),
        clipboardService: MemoryClipboardService()
    )
    try await currentHistory.append(
        entry: TranscriptEntry(
            createdAt: insightTestDate(2026, 7, 9),
            appBundleID: "com.example.Editor",
            rawText: "recover these dictated words",
            cleanText: "Recover these dictated words.",
            durationMS: 8_000,
            audioURL: nil,
            insertionStatus: .inserted
        )
    )

    let analyticsURL = directory.appendingPathComponent("usage-analytics.json")
    let corruptBytes = Data("corrupt analytics sentinel 93741".utf8)
    try corruptBytes.write(to: analyticsURL, options: .atomic)
    let controller = DictationController(
        hotkey: InsightsTestHotkeyService(),
        historyStore: currentHistory,
        usageAnalyticsStore: UsageAnalyticsStore(storageURL: analyticsURL),
        legacyHistoryURL: directory.appendingPathComponent("missing-legacy.json")
    )
    defer { controller.teardown() }

    await controller.refreshUsageAnalytics(
        now: insightTestDate(2026, 7, 10),
        calendar: insightTestCalendar()
    )

    #expect(controller.usageAnalyticsSnapshot.totalSessions == 1)
    #expect(controller.usageAnalyticsSnapshot.totalWords == 4)
    #expect(controller.usageAnalyticsError.contains("preserved"))

    let backups = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("usage-analytics.corrupt-") }
    #expect(backups.count == 1)
    let backupURL = try #require(backups.first)
    #expect(try Data(contentsOf: backupURL) == corruptBytes)
}

@MainActor
@Test("An exact analytics write warning remains visible after refresh")
func analyticsWriteWarningSurvivesRefresh() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoInsightsWarningTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let historyStore = HistoryStore(
        storageURL: directory.appendingPathComponent("current-history.json"),
        clipboardService: MemoryClipboardService()
    )
    let controller = DictationController(
        hotkey: InsightsTestHotkeyService(),
        mediaInterruption: InsightsNoopMediaInterruptionService(),
        coordinator: InsightsWarningCoordinator(
            historyStore: historyStore,
            createdAt: insightTestDate(2026, 7, 10)
        ),
        historyStore: historyStore,
        usageAnalyticsStore: UsageAnalyticsStore(
            storageURL: directory.appendingPathComponent("usage-analytics.json")
        ),
        legacyHistoryURL: directory.appendingPathComponent("missing-legacy.json")
    )
    defer { controller.teardown() }

    controller.pressToTalkStart()
    #expect(await waitForInsightsCondition { controller.isRecording })
    controller.pressToTalkStop()
    #expect(await waitForInsightsCondition { !controller.usageAnalyticsWriteWarning.isEmpty })
    #expect(await waitForInsightsCondition {
        controller.usageAnalyticsSnapshot.totalSessions == 1
    })
    let warning = controller.usageAnalyticsWriteWarning

    await controller.refreshUsageAnalytics(
        now: insightTestDate(2026, 7, 10),
        calendar: insightTestCalendar()
    )

    #expect(controller.usageAnalyticsWriteWarning == warning)
    #expect(controller.usageAnalyticsSnapshot.totalSessions == 1)
    #expect(controller.usageAnalyticsSnapshot.totalWords == 4)
    #expect(controller.usageAnalyticsSnapshot.totalDurationMS == 7_000)
    #expect(controller.usageAnalyticsSnapshot.estimatedCleanupSessionCount == 1)
}

@MainActor
@Test("Cleanup retry refreshes historical Insights estimates")
func cleanupRetryRefreshesUsageAnalytics() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoInsightsRetryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let historyStore = HistoryStore(
        storageURL: directory.appendingPathComponent("current-history.json"),
        clipboardService: MemoryClipboardService()
    )
    let entry = TranscriptEntry(
        createdAt: Date(),
        appBundleID: "com.example.Editor",
        rawText: "Call Bob, scratch that, Jane.",
        cleanText: "Call Bob, scratch that, Jane.",
        durationMS: 8_000,
        audioURL: nil,
        insertionStatus: .inserted
    )
    try await historyStore.append(entry: entry)

    let controller = DictationController(
        hotkey: InsightsTestHotkeyService(),
        historyStore: historyStore,
        usageAnalyticsStore: UsageAnalyticsStore(
            storageURL: directory.appendingPathComponent("usage-analytics.json")
        ),
        legacyHistoryURL: directory.appendingPathComponent("missing-legacy.json")
    )
    defer { controller.teardown() }

    await controller.refreshUsageAnalytics()
    #expect(controller.usageAnalyticsSnapshot.cleanupChanges.estimatedWordChanges == 0)

    controller.retryCleanup(for: entry)

    #expect(await waitForInsightsCondition {
        controller.usageAnalyticsSnapshot.cleanupChanges.estimatedWordChanges > 0
    })
    #expect(controller.usageAnalyticsSnapshot.totalSessions == 1)
}

@MainActor
@Test("Hosted app tests isolate default Insights storage")
func hostedTestsUseTemporaryInsightsStorage() {
    let storageURL = UsageAnalyticsStore.defaultStorageURL().standardizedFileURL
    let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
    let productionURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Steno", isDirectory: true)
        .appendingPathComponent("usage-analytics.json")
        .standardizedFileURL

    #expect(storageURL.path.hasPrefix(temporaryRoot.path))
    #expect(storageURL.path != productionURL.path)
    #expect(storageURL.deletingLastPathComponent().lastPathComponent.hasPrefix("StenoTests-"))
}

@MainActor
@Test("Overlapping forced Insights refresh reconciles the newest history")
func overlappingForcedInsightsRefreshIsCoalesced() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoInsightsOverlapRefreshTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let history = HistoryStore(
        storageURL: directory.appendingPathComponent("history.json"),
        clipboardService: MemoryClipboardService()
    )
    try await history.append(
        entry: TranscriptEntry(
            createdAt: insightTestDate(2026, 7, 9),
            appBundleID: "com.example.Editor",
            rawText: "first saved session",
            cleanText: "First saved session.",
            durationMS: 5_000,
            audioURL: nil,
            insertionStatus: .inserted
        )
    )
    let analyticsStore = BlockingUsageAnalyticsStore(
        storageURL: directory.appendingPathComponent("usage-analytics.json")
    )
    let controller = DictationController(
        hotkey: InsightsTestHotkeyService(),
        historyStore: history,
        usageAnalyticsStore: analyticsStore,
        legacyHistoryURL: directory.appendingPathComponent("missing-legacy.json")
    )
    defer { controller.teardown() }

    let firstRefresh = Task { @MainActor in
        await controller.refreshUsageAnalytics(
            now: insightTestDate(2026, 7, 10),
            calendar: insightTestCalendar()
        )
    }
    await analyticsStore.waitForFirstReconciliation()

    try await history.append(
        entry: TranscriptEntry(
            createdAt: insightTestDate(2026, 7, 10),
            appBundleID: "com.example.Editor",
            rawText: "second saved session",
            cleanText: "Second saved session.",
            durationMS: 6_000,
            audioURL: nil,
            insertionStatus: .inserted
        )
    )
    let recoveryRefresh = Task { @MainActor in
        await controller.refreshUsageAnalytics(
            now: insightTestDate(2026, 7, 10),
            calendar: insightTestCalendar(),
            forceHistoryReconciliation: true
        )
    }

    await Task.yield()
    await analyticsStore.releaseFirstReconciliation()
    await firstRefresh.value
    await recoveryRefresh.value

    #expect(controller.usageAnalyticsSnapshot.totalSessions == 2)
    #expect(await analyticsStore.reconciliationCount() == 2)
}

@MainActor
private final class InsightsTestHotkeyService: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16?

    func start() {}
    func stop() {}
}

private actor InsightsWarningCoordinator: DictationSessionCoordinating {
    private let historyStore: HistoryStore
    private let createdAt: Date

    init(historyStore: HistoryStore, createdAt: Date) {
        self.historyStore = historyStore
        self.createdAt = createdAt
    }

    func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        SessionID()
    }

    func endPressToTalkCapture(sessionID: SessionID) async throws {}

    func completePressToTalk(
        sessionID: SessionID,
        languageHints: [String]
    ) async throws -> InsertResult {
        try await historyStore.append(
            entry: TranscriptEntry(
                createdAt: createdAt,
                appBundleID: "com.example.Editor",
                rawText: "test transcript from history",
                cleanText: "Test transcript from history.",
                durationMS: 7_000,
                audioURL: nil,
                insertionStatus: .inserted
            )
        )
        return InsertResult(
            status: .inserted,
            method: .direct,
            insertedText: "Test transcript",
            usageAnalyticsWarning: "Exact usage details could not be saved."
        )
    }

    func cancel(sessionID: SessionID) async {}

    func setHandsFreeEnabled(_ enabled: Bool) async {}
}

private actor BlockingUsageAnalyticsStore: UsageAnalyticsStoreServicing {
    private let inner: UsageAnalyticsStore
    private var firstReconciliationStarted = false
    private var firstReconciliationReleased = false
    private var firstReconciliationWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstReconciliationRelease: CheckedContinuation<Void, Never>?
    private var reconcileCalls = 0

    init(storageURL: URL) {
        inner = UsageAnalyticsStore(storageURL: storageURL)
    }

    func waitForFirstReconciliation() async {
        guard !firstReconciliationStarted else { return }
        await withCheckedContinuation { continuation in
            firstReconciliationWaiters.append(continuation)
        }
    }

    func releaseFirstReconciliation() {
        firstReconciliationReleased = true
        firstReconciliationRelease?.resume()
        firstReconciliationRelease = nil
    }

    func reconciliationCount() -> Int {
        reconcileCalls
    }

    func recoverCorruptArchiveIfNeeded() async throws -> URL? {
        try await inner.recoverCorruptArchiveIfNeeded()
    }

    func record(event: UsageEvent) async throws {
        try await inner.record(event: event)
    }

    func reconcileHistory(
        legacyURL: URL?,
        currentEntries: [TranscriptEntry]
    ) async throws -> String? {
        reconcileCalls += 1
        if reconcileCalls == 1 {
            firstReconciliationStarted = true
            let waiters = firstReconciliationWaiters
            firstReconciliationWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            if !firstReconciliationReleased {
                await withCheckedContinuation { continuation in
                    firstReconciliationRelease = continuation
                }
            }
        }
        return try await inner.reconcileHistory(
            legacyURL: legacyURL,
            currentEntries: currentEntries
        )
    }

    func snapshot(
        now: Date,
        calendar: Calendar,
        months: Int
    ) async throws -> UsageAnalyticsSnapshot {
        try await inner.snapshot(now: now, calendar: calendar, months: months)
    }
}

@MainActor
private final class InsightsNoopMediaInterruptionService: MediaInterruptionService {
    func beginInterruption() async -> MediaInterruptionToken? { nil }
    func endInterruption(token: MediaInterruptionToken) async {}
}

@MainActor
private func waitForInsightsCondition(
    attempts: Int = 400,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

private func insightTestCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 1
    return calendar
}

private func insightTestDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    insightTestCalendar().date(
        from: DateComponents(year: year, month: month, day: day, hour: 12)
    )!
}
