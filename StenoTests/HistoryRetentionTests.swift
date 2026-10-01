import Foundation
import Testing
@testable import Steno
import StenoKit

@MainActor
private func seededController(
    daysAgo ages: [Double],
    in directory: URL,
    now: Date = Date()
) throws -> (DictationController, [TranscriptEntry], URL) {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let entries = ages.enumerated().map { index, age in
        TranscriptEntry(
            createdAt: now.addingTimeInterval(-age * 86_400),
            appBundleID: "com.example.Editor",
            rawText: "archived fictional note \(index)",
            cleanText: "Archived fictional note \(index).",
            durationMS: 3_000,
            audioURL: nil,
            insertionStatus: .inserted
        )
    }
    let historyURL = directory.appendingPathComponent("history.json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(entries).write(to: historyURL, options: .atomic)

    let controller = makeTestDictationController(
        hotkey: HistoryTestHotkeyService(),
        historyStore: HistoryStore(storageURL: historyURL, clipboardService: MemoryClipboardService()),
        usageAnalyticsStore: UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json")),
        legacyHistoryURL: directory.appendingPathComponent("absent-legacy.json")
    )
    return (controller, entries, historyURL)
}

@MainActor
@Test("History lists and searches entries older than 31 days")
func historyShowsEntriesOlderThanAMonth() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoHistoryRetention-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (controller, entries, _) = try seededController(daysAgo: [0, 12, 31.5, 45, 400], in: directory)
    defer { controller.teardown() }

    await controller.refreshHistory()

    #expect(controller.recentEntries.map(\.id) == entries.map(\.id))
    let listed = HistoryTab.entries(controller.recentEntries, matching: "", filter: .all)
    #expect(listed.map(\.id) == entries.map(\.id))
    let found = HistoryTab.entries(controller.recentEntries, matching: "note 4", filter: .all)
    #expect(found.map(\.id) == [entries[4].id])
    let inserted = HistoryTab.entries(controller.recentEntries, matching: "archived", filter: .inserted)
    #expect(inserted.count == entries.count)
}

@MainActor
@Test("Delete all removes every transcript and keeps Insights totals")
func deleteAllHistoryKeepsInsightsTotals() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoHistoryDeleteAll-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let (controller, entries, historyURL) = try seededController(
        daysAgo: [0, 3, 40, 90], in: directory, now: now
    )
    defer { controller.teardown() }

    await controller.refreshHistory()
    await controller.refreshUsageAnalytics(now: now)
    let before = controller.usageAnalyticsSnapshot
    #expect(before.totalSessions == entries.count)

    await controller.deleteAllHistory()

    #expect(controller.recentEntries.isEmpty)
    #expect(controller.lastError.isEmpty)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode([TranscriptEntry].self, from: Data(contentsOf: historyURL)).isEmpty)

    await controller.refreshUsageAnalytics(now: now, forceHistoryReconciliation: true)
    let after = controller.usageAnalyticsSnapshot
    #expect(after.totalSessions == before.totalSessions)
    #expect(after.totalWords == before.totalWords)
    #expect(after.totalDurationMS == before.totalDurationMS)
    #expect(after.activeDayCount == before.activeDayCount)
}

@MainActor
private final class HistoryTestHotkeyService: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16?

    func start() {}
    func stop() {}
}
