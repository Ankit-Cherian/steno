import Foundation
import Testing
@testable import StenoKit

@Suite("Usage ledger values from a newer version")
struct UsageLedgerForwardCompatibilityTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-forward-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entries(_ count: Int) -> [TranscriptEntry] {
        (0..<count).map { index in
            TranscriptEntry(
                createdAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(index) * 3_600),
                appBundleID: "com.example.Editor",
                rawText: "one two three",
                cleanText: "One two three.",
                durationMS: 2_000,
                audioURL: nil,
                insertionStatus: .inserted
            )
        }
    }

    /// Rewrites stored events as a newer build might: a new insertion status,
    /// duration quality and cleanup quality.
    private func injectFutureValues(into object: inout [String: Any], key: String = "events") throws {
        var events = try #require(object[key] as? [[String: Any]])
        events[0]["insertionStatus"] = "pastedLater"
        events[1]["durationQuality"] = "measuredOnDevice"
        events[2]["cleanupQuality"] = "verified"
        object[key] = events
    }

    @Test("One unknown value no longer quarantines the whole ledger or resets lifetime totals")
    func unknownValuesKeepLifetimeTotals() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let storageURL = folder.appendingPathComponent("usage-analytics.json")
        let seed = UsageAnalyticsStore(storageURL: storageURL)
        let history = entries(12)
        try await seed.backfill(
            entries: history,
            coverage: UsageCoverageInterval(start: history[0].createdAt, end: nil)
        )

        var archive = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: storageURL)) as? [String: Any]
        )
        try injectFutureValues(into: &archive)
        try JSONSerialization.data(withJSONObject: archive).write(to: storageURL)

        let store = UsageAnalyticsStore(storageURL: storageURL)
        #expect(try await store.recoverCorruptArchiveIfNeeded() == nil)
        let snapshot = try await store.snapshot(now: Date(timeIntervalSince1970: 1_780_100_000), months: 6)
        #expect(snapshot.totalSessions == 12)
        #expect(snapshot.totalWords == 36)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains { $0.contains("corrupt") })
    }

    @Test("A pending event with an unknown value is applied, not quarantined")
    func pendingSegmentWithUnknownValueIsKept() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let storageURL = folder.appendingPathComponent("usage-analytics.json")
        let store = UsageAnalyticsStore(storageURL: storageURL)
        let entry = entries(1)[0]
        try await store.record(event: .live(from: entry, captureDurationMS: 2_000, edits: []))

        let segments = folder.appendingPathComponent("usage-analytics-events", isDirectory: true)
        let segmentURL = try #require(try FileManager.default.contentsOfDirectory(
            at: segments,
            includingPropertiesForKeys: nil
        ).first)
        var segment = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: segmentURL)) as? [String: Any]
        )
        var event = try #require(segment["event"] as? [String: Any])
        event["insertionStatus"] = "pastedLater"
        event["durationQuality"] = "measuredOnDevice"
        segment["event"] = event
        try JSONSerialization.data(withJSONObject: segment).write(to: segmentURL)

        let reloaded = UsageAnalyticsStore(storageURL: storageURL)
        #expect(try await reloaded.recoverCorruptArchiveIfNeeded() == nil)
        let snapshot = try await reloaded.snapshot(now: Date(timeIntervalSince1970: 1_780_100_000), months: 6)
        #expect(snapshot.totalSessions == 1)
        #expect(snapshot.totalDurationMS == 2_000)
    }

    @Test("A ledger rewritten after reading unknown values decodes with the 1.0.0 types")
    func rewrittenLedgerLoadsInReleasedVersion() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let storageURL = folder.appendingPathComponent("usage-analytics.json")
        let history = entries(6)
        let seed = UsageAnalyticsStore(storageURL: storageURL)
        try await seed.backfill(
            entries: history,
            coverage: UsageCoverageInterval(start: history[0].createdAt, end: nil)
        )
        var archive = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: storageURL)) as? [String: Any]
        )
        try injectFutureValues(into: &archive)
        try JSONSerialization.data(withJSONObject: archive).write(to: storageURL)

        let store = UsageAnalyticsStore(storageURL: storageURL)
        try await store.backfill(
            entries: entries(8),
            coverage: UsageCoverageInterval(start: history[0].createdAt, end: nil)
        )

        let released = try Released100.decoder().decode(
            Released100.UsageArchive.self,
            from: Data(contentsOf: storageURL)
        )
        #expect(released.events.count == 14)
    }
}
