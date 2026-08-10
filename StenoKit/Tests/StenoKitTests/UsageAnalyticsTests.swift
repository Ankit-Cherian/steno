import Foundation
import Testing
import StenoKitTestSupport
@testable import StenoKit

@Suite("Usage analytics metrics")
struct UsageAnalyticsMetricsTests {
    @Test("Live usage events keep exact edit counts without transcript text")
    func liveEventKeepsOnlyPrivateMetrics() throws {
        let entry = TranscriptEntry(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            createdAt: testDate(2026, 7, 10, hour: 14),
            appBundleID: "com.apple.Notes",
            rawText: "um hello world",
            cleanText: "Hello, world.",
            durationMS: 9_000,
            audioURL: nil,
            insertionStatus: .inserted
        )
        let edits = [
            TranscriptEdit(kind: .fillerRemoval, from: "um", to: ""),
            TranscriptEdit(kind: .punctuation, from: "hello world", to: "Hello, world."),
            TranscriptEdit(kind: .lexiconCorrection, from: "world", to: "World"),
        ]

        let event = UsageEvent.live(
            from: entry,
            captureDurationMS: 10_000,
            edits: edits
        )

        #expect(event.id == entry.id)
        #expect(event.rawWordCount == 3)
        #expect(event.finalWordCount == 2)
        #expect(event.durationMS == 10_000)
        #expect(event.durationQuality == .captureExact)
        #expect(event.cleanupQuality == .exact)
        #expect(event.cleanupChanges.total == 3)
        #expect(event.cleanupChanges.fillerRemovals == 1)
        #expect(event.cleanupChanges.punctuationChanges == 1)
        #expect(event.cleanupChanges.lexiconCorrections == 1)

        let encoded = try JSONEncoder().encode(event)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains(entry.rawText))
        #expect(!json.contains(entry.cleanText))
        #expect(!json.contains("hello"))
    }

    @Test("History backfill derives estimated cleanup changes and duration quality")
    func backfillMetricsAreMarkedEstimated() {
        let entry = TranscriptEntry(
            createdAt: testDate(2026, 6, 21),
            appBundleID: "com.example.Editor",
            rawText: "um ship the feature",
            cleanText: "Ship the feature.",
            durationMS: 12_000,
            audioURL: nil,
            insertionStatus: .copiedOnly
        )

        let event = UsageEvent.backfilled(from: entry)

        #expect(event.rawWordCount == 4)
        #expect(event.finalWordCount == 3)
        #expect(event.cleanupChanges.total == 3)
        #expect(event.cleanupQuality == .estimated)
        #expect(event.durationMS == 12_000)
        #expect(event.durationQuality == .transcriptEstimate)
    }

    @Test("Historical cleanup estimates include case and punctuation edits")
    func backfillCountsCaseAndPunctuationEdits() {
        let entry = TranscriptEntry(
            createdAt: testDate(2026, 6, 21),
            appBundleID: "com.example.Editor",
            rawText: "hello world",
            cleanText: "Hello, world.",
            durationMS: 4_000,
            audioURL: nil,
            insertionStatus: .inserted
        )

        let event = UsageEvent.backfilled(from: entry)

        #expect(event.rawWordCount == 2)
        #expect(event.finalWordCount == 2)
        #expect(event.cleanupChanges.estimatedWordChanges == 3)
        #expect(event.cleanupQuality == .estimated)
    }

    @Test("Historical cleanup treats apostrophe typography as one edit")
    func backfillHandlesTypographicApostrophes() {
        let typographyEntry = TranscriptEntry(
            createdAt: testDate(2026, 6, 21),
            appBundleID: "com.example.Editor",
            rawText: "don't stop",
            cleanText: "don’t stop",
            durationMS: 4_000,
            audioURL: nil,
            insertionStatus: .inserted
        )
        let whitespaceEntry = TranscriptEntry(
            createdAt: testDate(2026, 6, 21),
            appBundleID: "com.example.Editor",
            rawText: "hello   world",
            cleanText: "hello world",
            durationMS: 4_000,
            audioURL: nil,
            insertionStatus: .inserted
        )

        let typographyEvent = UsageEvent.backfilled(from: typographyEntry)
        let whitespaceEvent = UsageEvent.backfilled(from: whitespaceEntry)

        #expect(typographyEvent.rawWordCount == 2)
        #expect(typographyEvent.finalWordCount == 2)
        #expect(typographyEvent.cleanupChanges.estimatedWordChanges == 1)
        #expect(whitespaceEvent.cleanupChanges.estimatedWordChanges == 0)
    }

    @Test("Snapshot aggregates weighted WPM, apps, streaks, and coverage gaps")
    func snapshotAggregatesUsage() throws {
        let calendar = testCalendar()
        let now = testDate(2026, 7, 10, hour: 15)
        let events = [
            makeUsageEvent(day: 6, app: "com.apple.Notes", words: 120, durationMS: 60_000),
            makeUsageEvent(day: 7, app: "com.apple.Notes", words: 80, durationMS: 40_000),
            makeUsageEvent(day: 9, app: "com.example.Editor", words: 90, durationMS: 30_000),
            makeUsageEvent(day: 10, app: "com.apple.Notes", words: 210, durationMS: 90_000),
        ]
        let coverage = [
            UsageCoverageInterval(
                start: testDate(2026, 2, 11),
                end: testDate(2026, 2, 11, hour: 23)
            ),
            UsageCoverageInterval(start: testDate(2026, 6, 21), end: nil),
        ]

        let snapshot = UsageAnalyticsCalculator.snapshot(
            events: events,
            coverage: coverage,
            now: now,
            calendar: calendar,
            months: 6
        )

        #expect(snapshot.totalSessions == 4)
        #expect(snapshot.totalWords == 500)
        #expect(snapshot.totalDurationMS == 220_000)
        #expect(abs(snapshot.averageWordsPerMinute - 136.3636) < 0.001)
        #expect(snapshot.activeDayCount == 4)
        #expect(snapshot.currentStreak == 2)
        #expect(snapshot.longestKnownStreak == 2)
        #expect(snapshot.exactDurationSessionCount == 4)
        #expect(snapshot.estimatedDurationSessionCount == 0)
        #expect(snapshot.unavailableDurationSessionCount == 0)
        #expect(snapshot.topApps.first?.appBundleID == "com.apple.Notes")
        #expect(snapshot.topApps.first?.sessionCount == 3)

        let february11 = try #require(snapshot.day(containing: testDate(2026, 2, 11), calendar: calendar))
        let february12 = try #require(snapshot.day(containing: testDate(2026, 2, 12), calendar: calendar))
        let june27 = try #require(snapshot.day(containing: testDate(2026, 6, 27), calendar: calendar))
        let july10 = try #require(snapshot.day(containing: testDate(2026, 7, 10), calendar: calendar))

        #expect(february11.isTracked)
        #expect(!february11.isActive)
        #expect(!february12.isTracked)
        #expect(june27.isTracked)
        #expect(!june27.isActive)
        #expect(july10.isActive)
        #expect(july10.isInCurrentStreak)
    }

    @Test("Mixed metric provenance survives daily, app, and lifetime summaries")
    func mixedMetricProvenanceStaysVisible() throws {
        let calendar = testCalendar()
        let createdAt = testDate(2026, 7, 10, hour: 12)
        let events = [
            UsageEvent(
                id: UUID(),
                createdAt: createdAt,
                appBundleID: "com.example.Editor",
                rawWordCount: 60,
                finalWordCount: 59,
                durationMS: 60_000,
                durationQuality: .captureExact,
                cleanupChanges: UsageCleanupBreakdown(fillerRemovals: 1),
                cleanupQuality: .exact,
                insertionStatus: .inserted
            ),
            UsageEvent(
                id: UUID(),
                createdAt: createdAt.addingTimeInterval(1),
                appBundleID: "com.example.Editor",
                rawWordCount: 30,
                finalWordCount: 29,
                durationMS: 30_000,
                durationQuality: .transcriptEstimate,
                cleanupChanges: UsageCleanupBreakdown(estimatedWordChanges: 2),
                cleanupQuality: .estimated,
                insertionStatus: .copiedOnly
            ),
            UsageEvent(
                id: UUID(),
                createdAt: createdAt.addingTimeInterval(2),
                appBundleID: "com.example.Editor",
                rawWordCount: 900,
                finalWordCount: 900,
                durationMS: 0,
                durationQuality: .unavailable,
                cleanupChanges: UsageCleanupBreakdown(punctuationChanges: 1),
                cleanupQuality: .exact,
                insertionStatus: .inserted
            ),
        ]

        let snapshot = UsageAnalyticsCalculator.snapshot(
            events: events,
            coverage: [],
            now: createdAt,
            calendar: calendar,
            months: 6
        )
        let day = try #require(snapshot.day(containing: createdAt, calendar: calendar))
        let app = try #require(snapshot.topApps.first)

        #expect(snapshot.totalSessions == 3)
        #expect(snapshot.totalWords == 990)
        #expect(snapshot.totalDurationMS == 90_000)
        #expect(abs(snapshot.averageWordsPerMinute - 60) < 0.001)
        #expect(snapshot.exactCleanupSessionCount == 2)
        #expect(snapshot.estimatedCleanupSessionCount == 1)
        #expect(snapshot.cleanupChanges.fillerRemovals == 1)
        #expect(snapshot.cleanupChanges.punctuationChanges == 1)
        #expect(snapshot.cleanupChanges.estimatedWordChanges == 2)

        #expect(day.isActive)
        #expect(day.isTracked)
        #expect(day.durationMS == 90_000)
        #expect(day.estimatedDurationSessionCount == 1)
        #expect(day.unavailableDurationSessionCount == 1)

        #expect(app.appBundleID == "com.example.Editor")
        #expect(app.durationMS == 90_000)
        #expect(app.estimatedDurationSessionCount == 1)
        #expect(app.unavailableDurationSessionCount == 1)
    }

    @Test("Streak calculations use local calendar days across a month boundary")
    func streakUsesLocalCalendarDays() {
        let calendar = testCalendar()
        let now = testDate(2026, 7, 2, hour: 12)
        let events = [
            makeUsageEvent(month: 6, day: 29),
            makeUsageEvent(month: 6, day: 30),
            makeUsageEvent(month: 7, day: 1),
            makeUsageEvent(month: 7, day: 2),
        ]

        let snapshot = UsageAnalyticsCalculator.snapshot(
            events: events,
            coverage: [UsageCoverageInterval(start: testDate(2026, 6, 29), end: nil)],
            now: now,
            calendar: calendar,
            months: 6
        )

        #expect(snapshot.currentStreak == 4)
        #expect(snapshot.longestKnownStreak == 4)
    }

    @Test("Calendar rows and streaks stay correct across New York DST changes")
    func calendarHandlesDaylightSavingTransitions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        calendar.firstWeekday = 1

        let ranges = [
            [
                localDate(2026, 3, 7, calendar: calendar),
                localDate(2026, 3, 8, calendar: calendar),
                localDate(2026, 3, 9, calendar: calendar),
            ],
            [
                localDate(2026, 10, 31, calendar: calendar),
                localDate(2026, 11, 1, calendar: calendar),
                localDate(2026, 11, 2, calendar: calendar),
            ],
        ]

        for dates in ranges {
            let events = dates.map { date in
                UsageEvent(
                    id: UUID(),
                    createdAt: date,
                    appBundleID: "com.apple.Notes",
                    rawWordCount: 10,
                    finalWordCount: 10,
                    durationMS: 10_000,
                    durationQuality: .captureExact,
                    cleanupChanges: .zero,
                    cleanupQuality: .exact,
                    insertionStatus: .inserted
                )
            }
            let snapshot = UsageAnalyticsCalculator.snapshot(
                events: events,
                coverage: [UsageCoverageInterval(start: dates[0], end: nil)],
                now: dates[2],
                calendar: calendar,
                months: 6
            )
            let activeRows = snapshot.dailyUsage.filter(\.isActive)

            #expect(activeRows.count == 3)
            #expect(Set(activeRows.map(\.date)).count == 3)
            #expect(activeRows.allSatisfy { $0.isTracked })
            #expect(snapshot.currentStreak == 3)
            #expect(snapshot.longestKnownStreak == 3)
        }
    }

    @Test("Lifetime totals retain known history outside the six-month calendar")
    func lifetimeTotalsOutliveCalendarWindow() {
        let calendar = testCalendar()
        let snapshot = UsageAnalyticsCalculator.snapshot(
            events: [
                makeUsageEvent(month: 1, day: 10, app: "com.apple.Notes", words: 100),
                makeUsageEvent(month: 7, day: 10, app: "com.example.Editor", words: 20),
            ],
            coverage: [UsageCoverageInterval(start: testDate(2026, 1, 10), end: nil)],
            now: testDate(2026, 7, 10),
            calendar: calendar,
            months: 6
        )

        #expect(snapshot.totalSessions == 2)
        #expect(snapshot.totalWords == 120)
        #expect(snapshot.activeDayCount == 2)
        #expect(snapshot.topApps.first?.appBundleID == "com.apple.Notes")
        #expect(!snapshot.dailyUsage.contains {
            calendar.isDate($0.date, inSameDayAs: testDate(2026, 1, 10))
        })
    }
}

@Suite("Usage analytics persistence")
struct UsageAnalyticsPersistenceTests {
    @Test("Default analytics storage is isolated under XCTest")
    func defaultStorageIsTestIsolated() {
        let temporaryRoot = URL(
            fileURLWithPath: "/tmp/steno-analytics-test-isolation",
            isDirectory: true
        )

        let url = UsageAnalyticsStore.defaultStorageURL(
            environment: ["XCTestConfigurationFilePath": "/tmp/tests.xctestconfiguration"],
            temporaryDirectory: temporaryRoot,
            processIdentifier: 42
        )

        #expect(url.path.hasPrefix(temporaryRoot.path))
        #expect(url.path.contains("StenoTests-42"))
        #expect(url.lastPathComponent == "usage-analytics.json")
    }

    @Test("Store backfill is idempotent, reloadable, and not capped at 500 events")
    func storeBackfillsAndReloads() async throws {
        let storageURL = temporaryJSONURL(prefix: "usage-analytics")
        let store = UsageAnalyticsStore(storageURL: storageURL)
        let entries = (0..<501).map { index in
            TranscriptEntry(
                id: UUID(),
                createdAt: testDate(2026, 6, 21).addingTimeInterval(Double(index)),
                appBundleID: "com.example.Editor",
                rawText: "hello world",
                cleanText: "Hello world.",
                durationMS: 1_000,
                audioURL: nil,
                insertionStatus: .copiedOnly
            )
        }
        let coverage = UsageCoverageInterval(start: testDate(2026, 6, 21), end: nil)

        try await store.backfill(entries: entries, coverage: coverage)
        let sentinelModificationDate = Date(timeIntervalSince1970: 946_684_800)
        try FileManager.default.setAttributes(
            [.modificationDate: sentinelModificationDate],
            ofItemAtPath: storageURL.path
        )
        try await store.backfill(entries: entries, coverage: coverage)

        let attributes = try FileManager.default.attributesOfItem(atPath: storageURL.path)
        let modificationDate = try #require(attributes[.modificationDate] as? Date)
        #expect(abs(modificationDate.timeIntervalSince(sentinelModificationDate)) < 0.001)

        let reloaded = UsageAnalyticsStore(storageURL: storageURL)
        let snapshot = try await reloaded.snapshot(
            now: testDate(2026, 7, 10),
            calendar: testCalendar(),
            months: 6
        )

        #expect(snapshot.totalSessions == 501)
        #expect(snapshot.totalWords == 1_002)
        #expect(snapshot.coverage.count == 1)
    }

    @Test("Version one ledgers load and upgrade on the next base write")
    func versionOneLedgerMigratesWithoutLosingEvents() async throws {
        let storageURL = temporaryJSONURL(prefix: "usage-v1")
        let existingCreatedAt = testDate(2026, 7, 9)
        let legacyJSON = #"""
        {
          "version": 1,
          "events": [{
            "id": "50000000-0000-0000-0000-000000000001",
            "createdAt": "2026-07-09T12:00:00Z",
            "appBundleID": "com.example.Editor",
            "rawWordCount": 12,
            "finalWordCount": 12,
            "durationMS": 10000,
            "durationQuality": "captureExact",
            "cleanupChanges": {
              "fillerRemovals": 0,
              "lexiconCorrections": 0,
              "repairResolutions": 0,
              "structureRewrites": 0,
              "punctuationChanges": 0,
              "commandTransforms": 0,
              "estimatedWordChanges": 0
            },
            "cleanupQuality": "exact",
            "insertionStatus": "inserted"
          }],
          "coverage": [{"start": "2026-07-09T12:00:00Z"}]
        }
        """#
        try Data(legacyJSON.utf8).write(to: storageURL, options: .atomic)

        let store = UsageAnalyticsStore(storageURL: storageURL)
        let beforeMigration = try await store.snapshot(
            now: testDate(2026, 7, 10),
            calendar: testCalendar()
        )
        #expect(beforeMigration.totalSessions == 1)
        #expect(beforeMigration.totalWords == 12)

        let added = makeUsageEvent(day: 10, words: 8)
        try await store.importBackfill(
            events: [added],
            coverage: UsageCoverageInterval(start: existingCreatedAt, end: nil)
        )

        let persistedObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: storageURL))
                as? [String: Any]
        )
        #expect(persistedObject["version"] as? Int == 2)
        #expect(persistedObject["appliedSegmentSequence"] as? Int == 0)

        let reloaded = UsageAnalyticsStore(storageURL: storageURL)
        let afterMigration = try await reloaded.snapshot(
            now: testDate(2026, 7, 10),
            calendar: testCalendar()
        )
        #expect(afterMigration.totalSessions == 2)
        #expect(afterMigration.totalWords == 20)
    }

    @Test("New live events persist without rewriting the lifetime archive")
    func liveEventsUseSegmentedPersistence() async throws {
        let storageURL = temporaryJSONURL(prefix: "segmented-usage")
        let store = UsageAnalyticsStore(storageURL: storageURL)
        let backfilled = makeUsageEvent(day: 9)
        try await store.importBackfill(
            events: [backfilled],
            coverage: UsageCoverageInterval(start: backfilled.createdAt, end: nil)
        )
        let originalArchive = try Data(contentsOf: storageURL)

        try await store.record(event: makeUsageEvent(day: 10))

        #expect(try Data(contentsOf: storageURL) == originalArchive)
        let reloaded = UsageAnalyticsStore(storageURL: storageURL)
        let snapshot = try await reloaded.snapshot(
            now: testDate(2026, 7, 10),
            calendar: testCalendar()
        )
        #expect(snapshot.totalSessions == 2)
    }

    @Test("No-op history reconciliation compacts exact live segments")
    func noOpReconciliationCompactsLiveSegments() async throws {
        let storageURL = temporaryJSONURL(prefix: "segment-no-op-compaction")
        let id = UUID()
        let createdAt = testDate(2026, 7, 10)
        let exact = UsageEvent(
            id: id,
            createdAt: createdAt,
            appBundleID: "com.example.Editor",
            rawWordCount: 4,
            finalWordCount: 4,
            durationMS: 12_000,
            durationQuality: .captureExact,
            cleanupChanges: .zero,
            cleanupQuality: .exact,
            insertionStatus: .inserted
        )
        let store = UsageAnalyticsStore(storageURL: storageURL)
        try await store.record(event: exact)

        let warning = try await store.reconcileHistory(
            legacyURL: nil,
            currentEntries: [
                TranscriptEntry(
                    id: id,
                    createdAt: createdAt,
                    appBundleID: "com.example.Editor",
                    rawText: "one two three four",
                    cleanText: "One two three four.",
                    durationMS: 12_000,
                    audioURL: nil,
                    insertionStatus: .inserted
                ),
            ]
        )

        #expect(warning == nil)
        #expect(FileManager.default.fileExists(atPath: storageURL.path))
        let remainingSegments = try FileManager.default.contentsOfDirectory(
            at: usageSegmentsDirectory(for: storageURL),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        #expect(remainingSegments.isEmpty)

        let reloaded = UsageAnalyticsStore(storageURL: storageURL)
        let snapshot = try await reloaded.snapshot(
            now: createdAt,
            calendar: testCalendar()
        )
        #expect(snapshot.totalSessions == 1)
        #expect(snapshot.totalWords == 4)
        #expect(snapshot.exactDurationSessionCount == 1)
        #expect(snapshot.exactCleanupSessionCount == 1)
    }

    @Test("A compacted base archive outranks stale event segments after reload")
    func compactedBaseOutranksStaleSegments() async throws {
        let storageURL = temporaryJSONURL(prefix: "segment-watermark")
        let store = UsageAnalyticsStore(storageURL: storageURL)
        let id = UUID()
        let createdAt = testDate(2026, 7, 10)
        let first = UsageEvent(
            id: id,
            createdAt: createdAt,
            appBundleID: "com.example.Editor",
            rawWordCount: 10,
            finalWordCount: 10,
            durationMS: 10_000,
            durationQuality: .captureExact,
            cleanupChanges: .zero,
            cleanupQuality: .exact,
            insertionStatus: .inserted
        )
        let corrected = UsageEvent(
            id: id,
            createdAt: createdAt,
            appBundleID: "com.example.Editor",
            rawWordCount: 40,
            finalWordCount: 40,
            durationMS: 20_000,
            durationQuality: .captureExact,
            cleanupChanges: UsageCleanupBreakdown(punctuationChanges: 1),
            cleanupQuality: .exact,
            insertionStatus: .inserted
        )

        try await store.record(event: first)
        let segmentsURL = usageSegmentsDirectory(for: storageURL)
        let staleURL = try #require(
            FileManager.default.contentsOfDirectory(
                at: segmentsURL,
                includingPropertiesForKeys: nil
            ).first
        )
        let staleBytes = try Data(contentsOf: staleURL)
        let staleFilename = staleURL.lastPathComponent
        try await store.importBackfill(
            events: [corrected],
            coverage: UsageCoverageInterval(start: createdAt, end: nil)
        )

        // Simulate a crash after the compacted base rename succeeds but before
        // best-effort stale-segment cleanup completes.
        try FileManager.default.createDirectory(
            at: segmentsURL,
            withIntermediateDirectories: true
        )
        try staleBytes.write(
            to: segmentsURL.appendingPathComponent(staleFilename),
            options: .atomic
        )

        let reloaded = UsageAnalyticsStore(storageURL: storageURL)
        let snapshot = try await reloaded.snapshot(
            now: createdAt,
            calendar: testCalendar()
        )
        #expect(snapshot.totalWords == 40)
        #expect(snapshot.totalDurationMS == 20_000)
        #expect(snapshot.cleanupChanges.punctuationChanges == 1)
    }

    @Test("Future event-segment schemas are preserved without quarantine")
    func futureSegmentSchemaIsPreserved() async throws {
        let storageURL = temporaryJSONURL(prefix: "future-segment")
        let store = UsageAnalyticsStore(storageURL: storageURL)
        try await store.importBackfill(
            events: [makeUsageEvent(day: 9)],
            coverage: UsageCoverageInterval(start: testDate(2026, 7, 9), end: nil)
        )
        let segmentsURL = usageSegmentsDirectory(for: storageURL)
        try FileManager.default.createDirectory(
            at: segmentsURL,
            withIntermediateDirectories: true
        )
        let futureURL = segmentsURL.appendingPathComponent("future.json")
        let futureBytes = Data(#"{"version":999,"sequence":1,"newEventSchema":{}}"#.utf8)
        try futureBytes.write(to: futureURL, options: .atomic)

        let reloaded = UsageAnalyticsStore(storageURL: storageURL)
        do {
            _ = try await reloaded.recoverCorruptArchiveIfNeeded()
            Issue.record("Expected the future segment version to be rejected")
        } catch UsageAnalyticsStoreError.unsupportedSegmentVersion(let version) {
            #expect(version == 999)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(try Data(contentsOf: futureURL) == futureBytes)
        let siblings = try FileManager.default.contentsOfDirectory(
            at: segmentsURL,
            includingPropertiesForKeys: nil
        )
        #expect(siblings.count == 1)
        #expect(siblings.first?.lastPathComponent == futureURL.lastPathComponent)
    }

    @Test("A corrupt segment is isolated without losing 501 valid exact events")
    func corruptSegmentRecoveryPreservesValidSegments() async throws {
        let storageURL = temporaryJSONURL(prefix: "recover-segment")
        let store = UsageAnalyticsStore(storageURL: storageURL)
        for index in 0..<501 {
            try await store.record(
                event: UsageEvent(
                    id: UUID(),
                    createdAt: testDate(2026, 7, 10).addingTimeInterval(Double(index)),
                    appBundleID: "com.example.Editor",
                    rawWordCount: 1,
                    finalWordCount: 1,
                    durationMS: 1_000,
                    durationQuality: .captureExact,
                    cleanupChanges: .zero,
                    cleanupQuality: .exact,
                    insertionStatus: .inserted
                )
            )
        }
        let segmentsURL = usageSegmentsDirectory(for: storageURL)
        let corruptURL = segmentsURL.appendingPathComponent("broken.json")
        let corruptBytes = Data("broken segment sentinel 71293".utf8)
        try corruptBytes.write(to: corruptURL, options: .atomic)

        let reloaded = UsageAnalyticsStore(storageURL: storageURL)
        let backupURL = try #require(
            await reloaded.recoverCorruptArchiveIfNeeded()
        )
        let snapshot = try await reloaded.snapshot(
            now: testDate(2026, 7, 10),
            calendar: testCalendar()
        )

        #expect(try Data(contentsOf: backupURL) == corruptBytes)
        #expect(snapshot.totalSessions == 501)
        #expect(snapshot.totalWords == 501)
    }

    @Test("Legacy and current histories reconcile in one current-wins transaction")
    func historiesReconcileAtomically() async throws {
        let storageURL = temporaryJSONURL(prefix: "reconciled-history")
        let legacyURL = temporaryJSONURL(prefix: "reconciled-legacy")
        let sharedID = UUID()
        let legacyJSON = """
        [{
          "id": "\(sharedID.uuidString)",
          "createdAt": "2026-07-10T12:00:00Z",
          "appBundleID": "com.example.Editor",
          "rawText": "stale",
          "cleanText": "Stale.",
          "durationMS": 1000,
          "insertionStatus": "copiedOnly"
        }]
        """
        try Data(legacyJSON.utf8).write(to: legacyURL, options: .atomic)
        let current = TranscriptEntry(
            id: sharedID,
            createdAt: testDate(2026, 7, 10),
            appBundleID: "com.example.Editor",
            rawText: "current words win here",
            cleanText: "Current words win here.",
            durationMS: 12_000,
            audioURL: nil,
            insertionStatus: .inserted
        )
        let store = UsageAnalyticsStore(storageURL: storageURL)

        let warning = try await store.reconcileHistory(
            legacyURL: legacyURL,
            currentEntries: [current]
        )
        let snapshot = try await store.snapshot(
            now: current.createdAt,
            calendar: testCalendar()
        )

        #expect(warning == nil)
        #expect(snapshot.totalSessions == 1)
        #expect(snapshot.totalWords == 4)
        #expect(snapshot.totalDurationMS == 12_000)
    }

    @Test("Repeated legacy and current reconciliation is physically idempotent")
    func repeatedHistoryReconciliationDoesNotRewrite() async throws {
        let storageURL = temporaryJSONURL(prefix: "reconciled-idempotence")
        let legacyURL = temporaryJSONURL(prefix: "reconciled-idempotence-legacy")
        let sharedID = UUID()
        let legacyJSON = """
        [{
          "id": "\(sharedID.uuidString)",
          "createdAt": "2026-07-10T12:00:00Z",
          "appBundleID": "com.example.Editor",
          "rawText": "stale",
          "cleanText": "Stale.",
          "durationMS": 1000,
          "insertionStatus": "copiedOnly"
        }]
        """
        try Data(legacyJSON.utf8).write(to: legacyURL, options: .atomic)
        let current = TranscriptEntry(
            id: sharedID,
            createdAt: testDate(2026, 7, 10),
            appBundleID: "com.example.Editor",
            rawText: "current words win here",
            cleanText: "Current words win here.",
            durationMS: 12_000,
            audioURL: nil,
            insertionStatus: .inserted
        )

        let firstStore = UsageAnalyticsStore(storageURL: storageURL)
        _ = try await firstStore.reconcileHistory(
            legacyURL: legacyURL,
            currentEntries: [current]
        )
        let sentinelModificationDate = Date(timeIntervalSince1970: 946_684_800)
        try FileManager.default.setAttributes(
            [.modificationDate: sentinelModificationDate],
            ofItemAtPath: storageURL.path
        )

        let reloadedStore = UsageAnalyticsStore(storageURL: storageURL)
        _ = try await reloadedStore.reconcileHistory(
            legacyURL: legacyURL,
            currentEntries: [current]
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: storageURL.path)
        let modificationDate = try #require(attributes[.modificationDate] as? Date)
        #expect(abs(modificationDate.timeIntervalSince(sentinelModificationDate)) < 0.001)

        let snapshot = try await reloadedStore.snapshot(
            now: current.createdAt,
            calendar: testCalendar()
        )
        #expect(snapshot.totalSessions == 1)
        #expect(snapshot.totalWords == 4)
        #expect(snapshot.totalDurationMS == 12_000)
    }

    @Test("Deleting transcript history does not erase retained usage aggregates")
    func emptyHistoryReconciliationRetainsImportedUsage() async throws {
        let storageURL = temporaryJSONURL(prefix: "retained-usage")
        let store = UsageAnalyticsStore(storageURL: storageURL)
        let entry = TranscriptEntry(
            id: UUID(),
            createdAt: testDate(2026, 7, 10),
            appBundleID: "com.example.Editor",
            rawText: "retained aggregate words",
            cleanText: "Retained aggregate words.",
            durationMS: 7_000,
            audioURL: nil,
            insertionStatus: .inserted
        )

        _ = try await store.reconcileHistory(
            legacyURL: nil,
            currentEntries: [entry]
        )
        _ = try await store.reconcileHistory(
            legacyURL: nil,
            currentEntries: []
        )
        let snapshot = try await store.snapshot(
            now: testDate(2026, 7, 10),
            calendar: testCalendar()
        )

        #expect(snapshot.totalSessions == 1)
        #expect(snapshot.totalWords == 3)
        #expect(snapshot.coverage.count == 1)
    }

    @Test("Unreadable legacy history warns without blocking current history")
    func malformedLegacyDoesNotBlockCurrentHistory() async throws {
        let storageURL = temporaryJSONURL(prefix: "reconciled-current")
        let legacyURL = temporaryJSONURL(prefix: "malformed-legacy")
        try Data("malformed legacy history sentinel".utf8).write(
            to: legacyURL,
            options: .atomic
        )
        let current = TranscriptEntry(
            createdAt: testDate(2026, 7, 10),
            appBundleID: "com.example.Editor",
            rawText: "current history remains available",
            cleanText: "Current history remains available.",
            durationMS: 12_000,
            audioURL: nil,
            insertionStatus: .inserted
        )
        let store = UsageAnalyticsStore(storageURL: storageURL)

        let warning = try await store.reconcileHistory(
            legacyURL: legacyURL,
            currentEntries: [current]
        )
        let snapshot = try await store.snapshot(
            now: current.createdAt,
            calendar: testCalendar()
        )

        #expect(warning != nil)
        #expect(snapshot.totalSessions == 1)
        #expect(snapshot.totalWords == 4)
    }

    @Test("An empty compatible history file is a successful no-op")
    func emptyHistoryIsNoOp() throws {
        let url = temporaryJSONURL(prefix: "empty-history")
        try Data("[]".utf8).write(to: url, options: .atomic)

        let batch = try UsageHistoryBackfillLoader.load(from: url)

        #expect(batch.events.isEmpty)
        #expect(batch.coverage == nil)
    }

    @Test("Legacy history without duration imports safely into a closed coverage interval")
    func legacyHistoryImportsWithoutDuration() throws {
        let url = temporaryJSONURL(prefix: "legacy-history")
        let id = "20000000-0000-0000-0000-000000000001"
        let json = """
        [{
          "id": "\(id)",
          "createdAt": "2026-02-11T19:57:29Z",
          "appBundleID": "dev.warp.Warp-Stable",
          "rawText": "um legacy words",
          "cleanText": "Legacy words.",
          "audioURL": "file:///tmp/legacy.wav",
          "insertionStatus": "copiedOnly"
        }]
        """
        try Data(json.utf8).write(to: url, options: .atomic)

        let batch = try UsageHistoryBackfillLoader.load(from: url)

        #expect(batch.events.count == 1)
        #expect(batch.events[0].id.uuidString == id)
        #expect(batch.events[0].durationMS == 0)
        #expect(batch.events[0].durationQuality == .unavailable)
        #expect(batch.events[0].cleanupQuality == .estimated)
        #expect(batch.coverage?.end != nil)
    }

    @Test("Corrupt analytics are not overwritten by a new event")
    func corruptArchiveFailsClosed() async throws {
        let storageURL = temporaryJSONURL(prefix: "corrupt-usage")
        let original = Data("not valid analytics".utf8)
        try original.write(to: storageURL, options: .atomic)
        let store = UsageAnalyticsStore(storageURL: storageURL)

        await #expect(throws: UsageAnalyticsStoreError.self) {
            try await store.record(event: makeUsageEvent(day: 10))
        }

        #expect(try Data(contentsOf: storageURL) == original)
    }

    @Test("Temporary base-ledger access failures are never quarantined")
    func inaccessibleBaseLedgerIsLeftInPlace() async throws {
        let storageURL = temporaryJSONURL(prefix: "inaccessible-base")
        try FileManager.default.createDirectory(
            at: storageURL,
            withIntermediateDirectories: true
        )
        let store = UsageAnalyticsStore(storageURL: storageURL)

        do {
            _ = try await store.recoverCorruptArchiveIfNeeded()
            Issue.record("Expected the unreadable ledger path to fail access")
        } catch UsageAnalyticsStoreError.accessFailed {
            // Expected: unreadable is not evidence that bytes are corrupt.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: storageURL.path,
            isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
    }

    @Test("Temporary event-segment access failures are never quarantined")
    func inaccessibleSegmentIsLeftInPlace() async throws {
        let storageURL = temporaryJSONURL(prefix: "inaccessible-segment")
        let store = UsageAnalyticsStore(storageURL: storageURL)
        try await store.importBackfill(
            events: [makeUsageEvent(day: 9)],
            coverage: UsageCoverageInterval(start: testDate(2026, 7, 9), end: nil)
        )
        let inaccessibleURL = usageSegmentsDirectory(for: storageURL)
            .appendingPathComponent("inaccessible.json", isDirectory: true)
        try FileManager.default.createDirectory(
            at: inaccessibleURL,
            withIntermediateDirectories: true
        )
        let reloaded = UsageAnalyticsStore(storageURL: storageURL)

        do {
            _ = try await reloaded.recoverCorruptArchiveIfNeeded()
            Issue.record("Expected the unreadable segment path to fail access")
        } catch UsageAnalyticsStoreError.accessFailed {
            // Expected: preserve the path and let a later refresh retry it.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: inaccessibleURL.path,
            isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
    }

    @Test("Corrupt analytics can be preserved and rebuilt explicitly")
    func corruptArchiveRecoveryPreservesOriginalBytes() async throws {
        let storageURL = temporaryJSONURL(prefix: "recover-corrupt-usage")
        let original = Data("damaged analytics sentinel 48271".utf8)
        try original.write(to: storageURL, options: .atomic)
        let store = UsageAnalyticsStore(storageURL: storageURL)

        let backupURL = try #require(
            await store.recoverCorruptArchiveIfNeeded()
        )

        #expect(try Data(contentsOf: backupURL) == original)
        try await store.record(event: makeUsageEvent(day: 10))
        let snapshot = try await store.snapshot(
            now: testDate(2026, 7, 10),
            calendar: testCalendar()
        )
        #expect(snapshot.totalSessions == 1)
    }

    @Test("Corrupt base recovery preserves valid pending usage events")
    func corruptBaseRecoveryKeepsPendingSegments() async throws {
        let storageURL = temporaryJSONURL(prefix: "recover-corrupt-base-with-segment")
        let event = UsageEvent(
            id: UUID(),
            createdAt: testDate(2026, 7, 10),
            appBundleID: "com.example.Editor",
            rawWordCount: 12,
            finalWordCount: 11,
            durationMS: 8_000,
            durationQuality: .captureExact,
            cleanupChanges: UsageCleanupBreakdown(fillerRemovals: 1),
            cleanupQuality: .exact,
            insertionStatus: .inserted
        )
        let initialStore = UsageAnalyticsStore(storageURL: storageURL)
        try await initialStore.record(event: event)

        let corruptBytes = Data("damaged base with valid segment sentinel 19573".utf8)
        try corruptBytes.write(to: storageURL, options: .atomic)
        let reloaded = UsageAnalyticsStore(storageURL: storageURL)

        let backupURL = try #require(
            await reloaded.recoverCorruptArchiveIfNeeded()
        )
        let snapshot = try await reloaded.snapshot(
            now: event.createdAt,
            calendar: testCalendar()
        )

        #expect(try Data(contentsOf: backupURL) == corruptBytes)
        #expect(snapshot.totalSessions == 1)
        #expect(snapshot.totalWords == 12)
        #expect(snapshot.totalDurationMS == 8_000)
        #expect(snapshot.exactDurationSessionCount == 1)
        #expect(snapshot.exactCleanupSessionCount == 1)
        #expect(snapshot.cleanupChanges.fillerRemovals == 1)
        #expect(snapshot.coverage.count == 1)
    }

    @Test("Future analytics versions are preserved without downgrade")
    func unsupportedVersionFailsClosed() async throws {
        let storageURL = temporaryJSONURL(prefix: "future-usage")
        let original = Data(#"{"version":3,"events":[],"coverage":[]}"#.utf8)
        try original.write(to: storageURL, options: .atomic)
        let store = UsageAnalyticsStore(storageURL: storageURL)

        do {
            try await store.record(event: makeUsageEvent(day: 10))
            Issue.record("Expected the future archive version to be rejected")
        } catch UsageAnalyticsStoreError.unsupportedVersion(let version) {
            #expect(version == 3)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(try Data(contentsOf: storageURL) == original)
    }

    @Test("Negative base watermarks fail closed before segment allocation")
    func negativeWatermarksAreRejected() async throws {
        for watermark in [-1, Int.min] {
            let storageURL = temporaryJSONURL(prefix: "negative-watermark")
            let original = Data(
                "{\"version\":2,\"events\":[],\"coverage\":[],\"appliedSegmentSequence\":\(watermark)}".utf8
            )
            try original.write(to: storageURL, options: .atomic)
            let store = UsageAnalyticsStore(storageURL: storageURL)

            do {
                try await store.record(event: makeUsageEvent(day: 10))
                Issue.record("Expected negative watermark \(watermark) to be rejected")
            } catch UsageAnalyticsStoreError.corruptArchive {
                // Expected: never convert the negative value to an unsigned filename.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(try Data(contentsOf: storageURL) == original)
            #expect(!FileManager.default.fileExists(
                atPath: usageSegmentsDirectory(for: storageURL).path
            ))
        }
    }

    @Test("Semantically invalid base archives are preserved and quarantined")
    func invalidStoredMetricsAreRejected() async throws {
        let validEvent = storedUsageEventJSON()
        let scenarios: [(name: String, events: String, coverage: String)] = [
            (
                "negative-words",
                storedUsageEventJSON(rawWordCount: -1),
                "[]"
            ),
            (
                "unbounded-words",
                storedUsageEventJSON(rawWordCount: Int.max),
                "[]"
            ),
            (
                "duration-quality-mismatch",
                storedUsageEventJSON(durationMS: 0, durationQuality: "captureExact"),
                "[]"
            ),
            (
                "cleanup-quality-mismatch",
                storedUsageEventJSON(cleanupQuality: "exact", estimatedWordChanges: 1),
                "[]"
            ),
            (
                "duplicate-event-id",
                "\(validEvent),\(validEvent)",
                "[]"
            ),
            (
                "reversed-coverage",
                validEvent,
                #"[{"start":"2026-07-10T12:00:00Z","end":"2026-07-09T12:00:00Z"}]"#
            ),
        ]

        for scenario in scenarios {
            let storageURL = temporaryJSONURL(prefix: scenario.name)
            let original = Data(
                """
                {"version":2,"events":[\(scenario.events)],"coverage":\(scenario.coverage),"appliedSegmentSequence":0}
                """.utf8
            )
            try original.write(to: storageURL, options: .atomic)
            let store = UsageAnalyticsStore(storageURL: storageURL)

            do {
                _ = try await store.snapshot()
                Issue.record("Expected \(scenario.name) to be rejected")
            } catch UsageAnalyticsStoreError.corruptArchive {
                // Expected: syntactically valid but impossible metrics fail closed.
            } catch {
                Issue.record("Unexpected \(scenario.name) error: \(error)")
            }
            #expect(try Data(contentsOf: storageURL) == original)

            let backupURL = try #require(
                await store.recoverCorruptArchiveIfNeeded()
            )
            #expect(try Data(contentsOf: backupURL) == original)
            #expect(try await store.snapshot().totalSessions == 0)
        }
    }

    @Test("A semantically invalid event segment is isolated")
    func invalidStoredSegmentIsRejected() async throws {
        let storageURL = temporaryJSONURL(prefix: "invalid-segment-metrics")
        let segmentsURL = usageSegmentsDirectory(for: storageURL)
        try FileManager.default.createDirectory(
            at: segmentsURL,
            withIntermediateDirectories: true
        )
        let segmentURL = segmentsURL.appendingPathComponent("invalid.json")
        let original = Data(
            """
            {"version":1,"sequence":1,"event":\(storedUsageEventJSON(rawWordCount: -1))}
            """.utf8
        )
        try original.write(to: segmentURL, options: .atomic)
        let store = UsageAnalyticsStore(storageURL: storageURL)

        let backupURL = try #require(
            await store.recoverCorruptArchiveIfNeeded()
        )

        #expect(try Data(contentsOf: backupURL) == original)
        #expect(!FileManager.default.fileExists(atPath: segmentURL.path))
        #expect(try await store.snapshot().totalSessions == 0)
    }

    @Test("Duplicate event segment sequences isolate only the later file")
    func duplicateSegmentSequenceIsRejected() async throws {
        let storageURL = temporaryJSONURL(prefix: "duplicate-segment-sequence")
        let segmentsURL = usageSegmentsDirectory(for: storageURL)
        try FileManager.default.createDirectory(
            at: segmentsURL,
            withIntermediateDirectories: true
        )
        let firstURL = segmentsURL.appendingPathComponent("a.json")
        let duplicateURL = segmentsURL.appendingPathComponent("b.json")
        try Data(
            """
            {"version":1,"sequence":1,"event":\(storedUsageEventJSON())}
            """.utf8
        ).write(to: firstURL, options: .atomic)
        let duplicateBytes = Data(
            """
            {"version":1,"sequence":1,"event":\(storedUsageEventJSON(id: "60000000-0000-0000-0000-000000000002"))}
            """.utf8
        )
        try duplicateBytes.write(to: duplicateURL, options: .atomic)
        let store = UsageAnalyticsStore(storageURL: storageURL)

        let backupURL = try #require(
            await store.recoverCorruptArchiveIfNeeded()
        )
        let snapshot = try await store.snapshot(
            now: testDate(2026, 7, 10),
            calendar: testCalendar()
        )

        #expect(try Data(contentsOf: backupURL) == duplicateBytes)
        #expect(snapshot.totalSessions == 1)
        #expect(snapshot.totalWords == 10)
    }

    @Test("Future analytics schemas are never quarantined as corrupt")
    func incompatibleFutureSchemaIsPreserved() async throws {
        let storageURL = temporaryJSONURL(prefix: "future-schema-usage")
        let original = Data(#"{"version":3,"newLedger":{"segments":[]}}"#.utf8)
        try original.write(to: storageURL, options: .atomic)
        let store = UsageAnalyticsStore(storageURL: storageURL)

        do {
            _ = try await store.recoverCorruptArchiveIfNeeded()
            Issue.record("Expected the future archive schema to be rejected")
        } catch UsageAnalyticsStoreError.unsupportedVersion(let version) {
            #expect(version == 3)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(try Data(contentsOf: storageURL) == original)
    }

    @Test("Persisted backfill never stores transcript text or audio paths")
    func persistedBackfillIsTextFree() async throws {
        let storageURL = temporaryJSONURL(prefix: "private-usage")
        let store = UsageAnalyticsStore(storageURL: storageURL)
        let rawSentinel = "RawPrivateSentinel83917"
        let cleanSentinel = "CleanPrivateSentinel27461"
        let audioSentinel = "audio-private-sentinel-61048.wav"
        let entry = TranscriptEntry(
            createdAt: testDate(2026, 7, 10),
            appBundleID: "com.apple.Notes",
            rawText: rawSentinel,
            cleanText: cleanSentinel,
            durationMS: 7_000,
            audioURL: URL(fileURLWithPath: "/tmp/\(audioSentinel)"),
            insertionStatus: .inserted
        )

        try await store.backfill(
            entries: [entry],
            coverage: UsageCoverageInterval(start: entry.createdAt, end: nil)
        )
        try await store.record(
            event: UsageEvent.live(
                from: entry,
                captureDurationMS: 8_000,
                edits: []
            )
        )

        let persistedURLs = [storageURL] + (try FileManager.default.contentsOfDirectory(
            at: usageSegmentsDirectory(for: storageURL),
            includingPropertiesForKeys: nil
        ))
        let persisted = try persistedURLs
            .map { try String(decoding: Data(contentsOf: $0), as: UTF8.self) }
            .joined(separator: "\n")
        #expect(!persisted.contains(rawSentinel))
        #expect(!persisted.contains(cleanSentinel))
        #expect(!persisted.contains(audioSentinel))

        let reloaded = UsageAnalyticsStore(storageURL: storageURL)
        let snapshot = try await reloaded.snapshot(
            now: entry.createdAt,
            calendar: testCalendar(),
            months: 6
        )
        #expect(snapshot.totalSessions == 1)
        #expect(snapshot.totalWords == 1)
        #expect(snapshot.totalDurationMS == 8_000)
    }

    @Test("Recurring backfill cannot downgrade exact live metrics")
    func backfillPreservesExactLiveMetrics() async throws {
        let storageURL = temporaryJSONURL(prefix: "exact-merge")
        let store = UsageAnalyticsStore(storageURL: storageURL)
        let id = UUID()
        let createdAt = testDate(2026, 7, 10)
        let exact = UsageEvent(
            id: id,
            createdAt: createdAt,
            appBundleID: "com.apple.Notes",
            rawWordCount: 4,
            finalWordCount: 3,
            durationMS: 12_000,
            durationQuality: .captureExact,
            cleanupChanges: UsageCleanupBreakdown(fillerRemovals: 1),
            cleanupQuality: .exact,
            insertionStatus: .inserted
        )
        let reconstructed = UsageEvent(
            id: id,
            createdAt: createdAt,
            appBundleID: "com.apple.Notes",
            rawWordCount: 5,
            finalWordCount: 3,
            durationMS: 11_000,
            durationQuality: .transcriptEstimate,
            cleanupChanges: UsageCleanupBreakdown(estimatedWordChanges: 2),
            cleanupQuality: .estimated,
            insertionStatus: .inserted
        )

        try await store.record(event: exact)
        try await store.importBackfill(
            events: [reconstructed],
            coverage: UsageCoverageInterval(start: createdAt, end: nil)
        )

        let reloaded = UsageAnalyticsStore(storageURL: storageURL)
        let snapshot = try await reloaded.snapshot(
            now: createdAt,
            calendar: testCalendar(),
            months: 6
        )

        #expect(snapshot.totalSessions == 1)
        #expect(snapshot.totalDurationMS == 12_000)
        #expect(snapshot.exactDurationSessionCount == 1)
        #expect(snapshot.exactCleanupSessionCount == 1)
        #expect(snapshot.estimatedCleanupSessionCount == 0)
        #expect(snapshot.cleanupChanges.fillerRemovals == 1)
        #expect(snapshot.cleanupChanges.estimatedWordChanges == 0)
    }

    @Test("Backfill merges cleanup and duration quality independently")
    func backfillMergesIndependentQualityDimensions() async throws {
        let storageURL = temporaryJSONURL(prefix: "mixed-quality")
        let store = UsageAnalyticsStore(storageURL: storageURL)
        let createdAt = testDate(2026, 7, 10)
        let firstID = UUID()
        let secondID = UUID()

        try await store.record(
            event: UsageEvent(
                id: firstID,
                createdAt: createdAt,
                appBundleID: "com.apple.Notes",
                rawWordCount: 4,
                finalWordCount: 3,
                durationMS: 0,
                durationQuality: .unavailable,
                cleanupChanges: UsageCleanupBreakdown(fillerRemovals: 1),
                cleanupQuality: .exact,
                insertionStatus: .inserted
            )
        )
        try await store.record(
            event: UsageEvent(
                id: secondID,
                createdAt: createdAt.addingTimeInterval(1),
                appBundleID: "com.apple.Notes",
                rawWordCount: 7,
                finalWordCount: 6,
                durationMS: 9_000,
                durationQuality: .captureExact,
                cleanupChanges: UsageCleanupBreakdown(estimatedWordChanges: 1),
                cleanupQuality: .estimated,
                insertionStatus: .inserted
            )
        )

        try await store.importBackfill(
            events: [
                UsageEvent(
                    id: firstID,
                    createdAt: createdAt,
                    appBundleID: "com.apple.Notes",
                    rawWordCount: 5,
                    finalWordCount: 3,
                    durationMS: 8_000,
                    durationQuality: .transcriptEstimate,
                    cleanupChanges: UsageCleanupBreakdown(estimatedWordChanges: 2),
                    cleanupQuality: .estimated,
                    insertionStatus: .inserted
                ),
                UsageEvent(
                    id: secondID,
                    createdAt: createdAt.addingTimeInterval(1),
                    appBundleID: "com.apple.Notes",
                    rawWordCount: 7,
                    finalWordCount: 6,
                    durationMS: 8_000,
                    durationQuality: .transcriptEstimate,
                    cleanupChanges: UsageCleanupBreakdown(punctuationChanges: 2),
                    cleanupQuality: .exact,
                    insertionStatus: .inserted
                ),
            ],
            coverage: UsageCoverageInterval(start: createdAt, end: nil)
        )

        let reloaded = UsageAnalyticsStore(storageURL: storageURL)
        let snapshot = try await reloaded.snapshot(
            now: createdAt,
            calendar: testCalendar(),
            months: 6
        )

        #expect(snapshot.totalSessions == 2)
        #expect(snapshot.totalWords == 11)
        #expect(snapshot.totalDurationMS == 17_000)
        #expect(snapshot.exactCleanupSessionCount == 2)
        #expect(snapshot.estimatedCleanupSessionCount == 0)
        #expect(snapshot.exactDurationSessionCount == 1)
        #expect(snapshot.estimatedDurationSessionCount == 1)
        #expect(snapshot.cleanupChanges.fillerRemovals == 1)
        #expect(snapshot.cleanupChanges.punctuationChanges == 2)
        #expect(snapshot.cleanupChanges.estimatedWordChanges == 0)
    }
}

@Suite("Session usage recording")
struct SessionUsageRecordingTests {
    @Test("Completed dictation records one exact usage event")
    func completedDictationRecordsUsage() async throws {
        let recorder = UsageRecorderSpy()
        let coordinator = try makeCoordinator(usageRecorder: recorder)

        let sessionID = try await coordinator.startPressToTalk(
            appContext: AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
        )
        let result = try await coordinator.stopPressToTalk(sessionID: sessionID)
        let events = await recorder.recordedEvents()

        #expect(result.status == .inserted)
        #expect(events.count == 1)
        #expect(events[0].appBundleID == "com.apple.Notes")
        #expect(events[0].cleanupQuality == .exact)
        #expect(events[0].cleanupChanges.lexiconCorrections == 1)
        #expect(result.usageAnalyticsWarning == nil)
    }

    @Test("Analytics write failure never breaks dictation insertion")
    func analyticsFailureDoesNotBreakDictation() async throws {
        let recorder = UsageRecorderSpy(shouldFail: true)
        let coordinator = try makeCoordinator(usageRecorder: recorder)

        let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
        let result = try await coordinator.stopPressToTalk(sessionID: sessionID)

        #expect(result.status == .inserted)
        #expect(result.usageAnalyticsWarning != nil)
    }

    @Test("Usage is attributed to the capture start time")
    func usageUsesCaptureStartTime() async throws {
        let recorder = UsageRecorderSpy()
        let captureStart = testDate(2026, 7, 9, hour: 23)
        // No second wall-clock sample is supplied: elapsed time must come only
        // from the monotonic clock, even if the system clock changes mid-capture.
        let clock = SynchronousTestClock([captureStart])
        let continuousStart = ContinuousClock().now
        let continuousClock = SynchronousContinuousClock([
            continuousStart,
            continuousStart.advanced(by: .seconds(90)),
        ])
        let coordinator = try makeCoordinator(
            usageRecorder: recorder,
            now: { clock.now() },
            monotonicNow: { continuousClock.now() }
        )

        let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
        _ = try await coordinator.stopPressToTalk(sessionID: sessionID)
        let event = try #require(await recorder.recordedEvents().first)

        #expect(event.createdAt == captureStart)
        #expect(event.durationMS == 90_000)
    }

    @Test("Snippet expansion does not inflate dictated word counts")
    func snippetExpansionKeepsSpokenWordCount() async throws {
        let recorder = UsageRecorderSpy()
        let snippets = SnippetService(
            snippets: [
                Snippet(
                    trigger: "stenoh ships cleanly",
                    expansion: "Taylor Example, Product Lead, 100 Market Street, Example City"
                )
            ]
        )
        let coordinator = try makeCoordinator(
            usageRecorder: recorder,
            snippetService: snippets
        )

        let sessionID = try await coordinator.startPressToTalk(appContext: .unknown)
        _ = try await coordinator.stopPressToTalk(sessionID: sessionID)
        let event = try #require(await recorder.recordedEvents().first)

        #expect(event.rawWordCount == 3)
    }
}

private actor UsageRecorderSpy: UsageAnalyticsRecording {
    private var events: [UsageEvent] = []
    private let shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func record(event: UsageEvent) async throws {
        if shouldFail {
            throw UsageRecorderTestError.failed
        }
        events.append(event)
    }

    func recordedEvents() -> [UsageEvent] {
        events
    }
}

private enum UsageRecorderTestError: Error {
    case failed
}

private final class SynchronousTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(_ dates: [Date]) {
        self.dates = dates
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        guard !dates.isEmpty else {
            preconditionFailure("Unexpected wall-clock read")
        }
        return dates.removeFirst()
    }
}

private final class SynchronousContinuousClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instants: [ContinuousClock.Instant]

    init(_ instants: [ContinuousClock.Instant]) {
        self.instants = instants
    }

    func now() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        guard !instants.isEmpty else {
            preconditionFailure("Unexpected monotonic-clock read")
        }
        return instants.removeFirst()
    }
}

private struct ExactCleanupEngine: CleanupEngine {
    func cleanup(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> CleanTranscript {
        _ = profile
        _ = lexicon
        return CleanTranscript(
            text: "Steno ships cleanly.",
            edits: [
                TranscriptEdit(kind: .lexiconCorrection, from: "stenoh", to: "Steno"),
                TranscriptEdit(kind: .punctuation, from: "cleanly", to: "cleanly."),
            ]
        )
    }
}

private func makeCoordinator(
    usageRecorder: any UsageAnalyticsRecording,
    snippetService: SnippetService = SnippetService(),
    now: @escaping @Sendable () -> Date = Date.init,
    monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
) throws -> SessionCoordinator {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("audio-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)
    let historyURL = temporaryJSONURL(prefix: "session-history")

    return SessionCoordinator(
        captureService: StubAudioCaptureService(queuedAudioURLs: [audioURL]),
        transcriptionEngine: StaticTranscriptionEngine { _, _ in
            RawTranscript(text: "stenoh ships cleanly", durationMS: 8_000)
        },
        cleanupEngine: ExactCleanupEngine(),
        insertionService: InsertionService(
            transports: [
                ClosureInsertionTransport(method: .direct) { _, _ in }
            ]
        ),
        historyStore: HistoryStore(
            storageURL: historyURL,
            clipboardService: MemoryClipboardService()
        ),
        lexiconService: PersonalLexiconService(),
        styleProfileService: StyleProfileService(),
        snippetService: snippetService,
        usageRecorder: usageRecorder,
        now: now,
        monotonicNow: monotonicNow
    )
}

private func makeUsageEvent(
    month: Int = 7,
    day: Int,
    app: String = "com.example.Editor",
    words: Int = 10,
    durationMS: Int = 10_000
) -> UsageEvent {
    UsageEvent(
        id: UUID(),
        createdAt: testDate(2026, month, day, hour: 12),
        appBundleID: app,
        rawWordCount: words,
        finalWordCount: words,
        durationMS: durationMS,
        durationQuality: .captureExact,
        cleanupChanges: .zero,
        cleanupQuality: .exact,
        insertionStatus: .inserted
    )
}

private func storedUsageEventJSON(
    id: String = "60000000-0000-0000-0000-000000000001",
    rawWordCount: Int = 10,
    finalWordCount: Int = 9,
    durationMS: Int = 8_000,
    durationQuality: String = "captureExact",
    cleanupQuality: String = "exact",
    estimatedWordChanges: Int = 0
) -> String {
    """
    {"id":"\(id)","createdAt":"2026-07-10T12:00:00Z","appBundleID":"com.example.Editor","rawWordCount":\(rawWordCount),"finalWordCount":\(finalWordCount),"durationMS":\(durationMS),"durationQuality":"\(durationQuality)","cleanupChanges":{"fillerRemovals":1,"lexiconCorrections":0,"repairResolutions":0,"structureRewrites":0,"punctuationChanges":0,"commandTransforms":0,"estimatedWordChanges":\(estimatedWordChanges)},"cleanupQuality":"\(cleanupQuality)","insertionStatus":"inserted"}
    """
}

private func usageSegmentsDirectory(for storageURL: URL) -> URL {
    storageURL
        .deletingLastPathComponent()
        .appendingPathComponent(
            "\(storageURL.deletingPathExtension().lastPathComponent)-events",
            isDirectory: true
        )
}

private func testCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 1
    return calendar
}

private func testDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    hour: Int = 12
) -> Date {
    testCalendar().date(
        from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        )
    )!
}

private func localDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    calendar: Calendar
) -> Date {
    calendar.date(
        from: DateComponents(year: year, month: month, day: day, hour: 12)
    )!
}

private func temporaryJSONURL(prefix: String) -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("steno-usage-tests", isDirectory: true)
    try? FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory.appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
}

private extension UsageAnalyticsSnapshot {
    func day(containing date: Date, calendar: Calendar) -> DailyUsage? {
        dailyUsage.first { calendar.isDate($0.date, inSameDayAs: date) }
    }
}
