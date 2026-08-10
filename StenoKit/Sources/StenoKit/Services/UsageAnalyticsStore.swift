import Foundation

public enum UsageAnalyticsStoreError: Error, LocalizedError {
    case corruptArchive
    case unsupportedVersion(Int)
    case unsupportedSegmentVersion(Int)
    case accessFailed
    case persistenceFailed

    public var errorDescription: String? {
        switch self {
        case .corruptArchive:
            return "Usage insights could not read the existing analytics archive. The file was left unchanged."
        case .unsupportedVersion(let version):
            return "Usage insights archive version \(version) is not supported."
        case .unsupportedSegmentVersion(let version):
            return "Usage insights event version \(version) is not supported."
        case .accessFailed:
            return "Usage insights could not access the saved analytics ledger. The files were left unchanged."
        case .persistenceFailed:
            return "Usage insights could not be saved."
        }
    }
}

public struct UsageHistoryBackfillBatch: Sendable, Equatable {
    public var events: [UsageEvent]
    public var coverage: UsageCoverageInterval?

    public init(events: [UsageEvent], coverage: UsageCoverageInterval?) {
        self.events = events
        self.coverage = coverage
    }
}

public enum UsageHistoryBackfillLoader {
    public static func load(from url: URL) throws -> UsageHistoryBackfillBatch {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([CompatibleHistoryEntry].self, from: data)
        let events = entries.map { entry in
            UsageEvent.backfilled(
                id: entry.id,
                createdAt: entry.createdAt,
                appBundleID: entry.appBundleID,
                rawText: entry.rawText,
                cleanText: entry.cleanText,
                durationMS: entry.durationMS,
                insertionStatus: entry.insertionStatus
            )
        }
        guard !events.isEmpty else {
            return UsageHistoryBackfillBatch(events: [], coverage: nil)
        }
        guard let first = events.map(\UsageEvent.createdAt).min(),
              let last = events.map(\UsageEvent.createdAt).max()
        else {
            throw UsageAnalyticsStoreError.corruptArchive
        }
        return UsageHistoryBackfillBatch(
            events: events,
            coverage: UsageCoverageInterval(start: first, end: last)
        )
    }

    private struct CompatibleHistoryEntry: Decodable {
        var id: UUID
        var createdAt: Date
        var appBundleID: String
        var rawText: String
        var cleanText: String
        var durationMS: Int?
        var insertionStatus: InsertionStatus

        private enum CodingKeys: String, CodingKey {
            case id
            case createdAt
            case appBundleID
            case rawText
            case cleanText
            case durationMS
            case insertionStatus
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            appBundleID = try container.decodeIfPresent(String.self, forKey: .appBundleID) ?? "unknown"
            rawText = try container.decodeIfPresent(String.self, forKey: .rawText) ?? ""
            cleanText = try container.decodeIfPresent(String.self, forKey: .cleanText) ?? ""
            durationMS = try container.decodeIfPresent(Int.self, forKey: .durationMS)
            insertionStatus = try container.decodeIfPresent(
                InsertionStatus.self,
                forKey: .insertionStatus
            ) ?? .copiedOnly
        }
    }
}

/// The app owns one store instance for this ledger. Actor isolation serializes
/// that writer; separate processes or store instances must not write the same
/// URLs concurrently.
public actor UsageAnalyticsStore: UsageAnalyticsRecording {
    private static let maximumStoredWordCount = 10_000_000
    private static let maximumStoredCleanupCount = 10_000_000
    private static let maximumStoredDurationMS = 31 * 24 * 60 * 60 * 1_000

    private struct ArchiveHeader: Decodable {
        var version: Int
    }

    private struct LegacyArchive: Codable, Sendable {
        var version: Int
        var events: [UsageEvent]
        var coverage: [UsageCoverageInterval]
    }

    private struct Archive: Codable, Sendable {
        static let currentVersion = 2

        var version: Int
        var events: [UsageEvent]
        var coverage: [UsageCoverageInterval]
        var appliedSegmentSequence: Int

        static let empty = Archive(
            version: currentVersion,
            events: [],
            coverage: [],
            appliedSegmentSequence: 0
        )
    }

    private struct SegmentHeader: Decodable {
        var version: Int
    }

    private struct EventSegment: Codable, Sendable {
        static let currentVersion = 1

        var version: Int
        var sequence: Int
        var event: UsageEvent
    }

    private struct LoadedSegment {
        var url: URL
        var value: EventSegment
    }

    private struct CorruptSegmentError: Error {
        var url: URL
    }

    private let storageURL: URL
    private let eventSegmentsDirectoryURL: URL
    private var archive: Archive?
    private var needsSegmentCompaction = false

    public init(storageURL: URL? = nil) {
        let resolvedStorageURL = storageURL ?? Self.defaultStorageURL()
        self.storageURL = resolvedStorageURL
        self.eventSegmentsDirectoryURL = resolvedStorageURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(resolvedStorageURL.deletingPathExtension().lastPathComponent)-events",
                isDirectory: true
            )
    }

    public func record(event: UsageEvent) async throws {
        guard Self.isSemanticallyValid(event) else {
            throw UsageAnalyticsStoreError.persistenceFailed
        }
        var working = try loadArchive()
        let eventChanged = upsert(event, into: &working.events)
        let mergedCoverage = mergeCoverage(
            working.coverage + [UsageCoverageInterval(start: event.createdAt, end: nil)]
        )
        let coverageChanged = mergedCoverage != working.coverage
        guard eventChanged || coverageChanged else { return }

        working.coverage = mergedCoverage
        guard let persistedEvent = working.events.first(where: { $0.id == event.id }) else {
            throw UsageAnalyticsStoreError.persistenceFailed
        }
        guard working.appliedSegmentSequence >= 0,
              working.appliedSegmentSequence < Int.max
        else {
            throw UsageAnalyticsStoreError.persistenceFailed
        }
        let sequence = working.appliedSegmentSequence + 1
        try persistSegment(persistedEvent, sequence: sequence)
        working.appliedSegmentSequence = sequence
        archive = working
        needsSegmentCompaction = true
    }

    public func backfill(
        entries: [TranscriptEntry],
        coverage: UsageCoverageInterval
    ) async throws {
        try await importBackfill(
            events: entries.map(UsageEvent.backfilled(from:)),
            coverage: coverage
        )
    }

    public func importBackfill(
        events: [UsageEvent],
        coverage: UsageCoverageInterval
    ) async throws {
        guard events.allSatisfy(Self.isSemanticallyValid),
              Self.isSemanticallyValid(coverage)
        else {
            throw UsageAnalyticsStoreError.persistenceFailed
        }
        var working = try loadArchive()
        let didChange = mergeBackfill(
            events: events,
            coverage: coverage,
            into: &working
        )
        guard didChange || needsSegmentCompaction else { return }
        try persist(working)
    }

    /// Loads and imports a compatible history file on the store actor so disk
    /// I/O and token-diff reconstruction do not run on a UI-isolated caller.
    public func importHistory(from url: URL) async throws {
        let batch = try UsageHistoryBackfillLoader.load(from: url)
        guard let coverage = batch.coverage else { return }
        try await importBackfill(events: batch.events, coverage: coverage)
    }

    /// Reconciles both recoverable history sources in one base-archive write.
    /// Legacy decoding is advisory: current Steno history still imports when an
    /// older compatible file is unreadable, and the caller receives a warning.
    public func reconcileHistory(
        legacyURL: URL?,
        currentEntries: [TranscriptEntry]
    ) async throws -> String? {
        var legacyBatch: UsageHistoryBackfillBatch?
        var legacyWarning: String?
        if let legacyURL {
            do {
                legacyBatch = try UsageHistoryBackfillLoader.load(from: legacyURL)
            } catch {
                legacyWarning = error.localizedDescription
            }
        }

        var working = try loadArchive()
        let originalEvents = working.events
        let originalCoverage = working.coverage

        if let legacyBatch {
            _ = mergeBackfill(
                events: legacyBatch.events,
                coverage: legacyBatch.coverage,
                into: &working
            )
        }

        let currentEvents = currentEntries.map(UsageEvent.backfilled(from:))
        let currentCoverage = currentEntries
            .map(\TranscriptEntry.createdAt)
            .min()
            .map { UsageCoverageInterval(start: $0, end: nil) }
        _ = mergeBackfill(
            events: currentEvents,
            coverage: currentCoverage,
            into: &working
        )

        let didChange = working.events != originalEvents
            || working.coverage != originalCoverage
        if didChange || needsSegmentCompaction {
            try persist(working)
        }
        return legacyWarning
    }

    /// Moves an unreadable archive aside before starting a fresh ledger. This
    /// is deliberately explicit: unsupported future versions are returned as
    /// errors and are never treated as corrupt or downgraded.
    @discardableResult
    public func recoverCorruptArchiveIfNeeded() async throws -> URL? {
        var firstRecoveredURL: URL?

        while true {
            archive = nil
            needsSegmentCompaction = false
            do {
                _ = try loadArchive()
                return firstRecoveredURL
            } catch let error as CorruptSegmentError {
                let recoveredURL = try quarantineCorruptSegment(at: error.url)
                firstRecoveredURL = firstRecoveredURL ?? recoveredURL
            } catch UsageAnalyticsStoreError.corruptArchive {
                guard FileManager.default.fileExists(atPath: storageURL.path) else {
                    throw UsageAnalyticsStoreError.corruptArchive
                }
                let recoveredURL = try quarantineCorruptBaseArchive()
                firstRecoveredURL = firstRecoveredURL ?? recoveredURL
            } catch let error as UsageAnalyticsStoreError {
                throw error
            } catch {
                throw error
            }
        }
    }

    public func snapshot(
        now: Date = Date(),
        calendar: Calendar = .current,
        months: Int = 6
    ) async throws -> UsageAnalyticsSnapshot {
        let loaded = try loadArchive()
        return UsageAnalyticsCalculator.snapshot(
            events: loaded.events,
            coverage: loaded.coverage,
            now: now,
            calendar: calendar,
            months: months
        )
    }

    public static func defaultStorageURL() -> URL {
        defaultStorageURL(
            environment: ProcessInfo.processInfo.environment,
            temporaryDirectory: FileManager.default.temporaryDirectory,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
    }

    static func defaultStorageURL(
        environment: [String: String],
        temporaryDirectory: URL,
        processIdentifier: Int32
    ) -> URL {
        let isRunningTests = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
        if isRunningTests {
            return temporaryDirectory
                .appendingPathComponent(
                    "StenoTests-\(processIdentifier)",
                    isDirectory: true
                )
                .appendingPathComponent("usage-analytics.json")
        }

        let appSupport: URL
        if let resolved = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            appSupport = resolved
        } else {
            appSupport = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        return appSupport
            .appendingPathComponent("Steno", isDirectory: true)
            .appendingPathComponent("usage-analytics.json")
    }

    private func loadArchive() throws -> Archive {
        if let archive {
            return archive
        }

        var loaded = try loadBaseArchive()
        let baseWatermark = loaded.appliedSegmentSequence
        let segments = try loadSegments()
        needsSegmentCompaction = !segments.isEmpty
        let pendingSegments = segments.filter {
            $0.value.sequence > baseWatermark
        }
        for segment in pendingSegments {
            _ = upsert(segment.value.event, into: &loaded.events)
            loaded.appliedSegmentSequence = max(
                loaded.appliedSegmentSequence,
                segment.value.sequence
            )
        }
        if let earliestSegmentDate = pendingSegments
            .map({ $0.value.event.createdAt })
            .min() {
            loaded.coverage = mergeCoverage(
                loaded.coverage + [UsageCoverageInterval(start: earliestSegmentDate, end: nil)]
            )
        }
        archive = loaded
        return loaded
    }

    private func loadBaseArchive() throws -> Archive {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return .empty
        }

        let data: Data
        do {
            data = try Data(contentsOf: storageURL)
        } catch {
            throw UsageAnalyticsStoreError.accessFailed
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let header = try decoder.decode(ArchiveHeader.self, from: data)
            switch header.version {
            case 1:
                let legacy = try decoder.decode(LegacyArchive.self, from: data)
                let upgraded = Archive(
                    version: Archive.currentVersion,
                    events: legacy.events,
                    coverage: legacy.coverage,
                    appliedSegmentSequence: 0
                )
                guard Self.isSemanticallyValid(upgraded) else {
                    throw UsageAnalyticsStoreError.corruptArchive
                }
                return upgraded
            case Archive.currentVersion:
                let decoded = try decoder.decode(Archive.self, from: data)
                guard Self.isSemanticallyValid(decoded) else {
                    throw UsageAnalyticsStoreError.corruptArchive
                }
                return decoded
            default:
                throw UsageAnalyticsStoreError.unsupportedVersion(header.version)
            }
        } catch let error as UsageAnalyticsStoreError {
            throw error
        } catch {
            throw UsageAnalyticsStoreError.corruptArchive
        }
    }

    private func loadSegments() throws -> [LoadedSegment] {
        guard FileManager.default.fileExists(atPath: eventSegmentsDirectoryURL.path) else {
            return []
        }

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: eventSegmentsDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw UsageAnalyticsStoreError.accessFailed
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [LoadedSegment] = []
        for url in urls
            .filter({ $0.pathExtension == "json" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw UsageAnalyticsStoreError.accessFailed
            }

            let header: SegmentHeader
            do {
                header = try decoder.decode(SegmentHeader.self, from: data)
            } catch {
                throw CorruptSegmentError(url: url)
            }
            guard header.version == EventSegment.currentVersion else {
                throw UsageAnalyticsStoreError.unsupportedSegmentVersion(header.version)
            }

            let segment: EventSegment
            do {
                segment = try decoder.decode(EventSegment.self, from: data)
            } catch {
                throw CorruptSegmentError(url: url)
            }
            guard segment.sequence > 0,
                  Self.isSemanticallyValid(segment.event)
            else {
                throw CorruptSegmentError(url: url)
            }
            loaded.append(LoadedSegment(url: url, value: segment))
        }

        let sorted = loaded.sorted {
            if $0.value.sequence == $1.value.sequence {
                return $0.url.lastPathComponent < $1.url.lastPathComponent
            }
            return $0.value.sequence < $1.value.sequence
        }
        var seenSequences: Set<Int> = []
        for segment in sorted where !seenSequences.insert(segment.value.sequence).inserted {
            throw CorruptSegmentError(url: segment.url)
        }
        return sorted
    }

    private func persist(_ newArchive: Archive) throws {
        var committedArchive = newArchive
        committedArchive.version = Archive.currentVersion
        guard Self.isSemanticallyValid(committedArchive) else {
            throw UsageAnalyticsStoreError.persistenceFailed
        }
        do {
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(committedArchive)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            throw UsageAnalyticsStoreError.persistenceFailed
        }

        archive = committedArchive
        needsSegmentCompaction = removeAppliedSegments(
            upTo: committedArchive.appliedSegmentSequence
        )
    }

    private func persistSegment(_ event: UsageEvent, sequence: Int) throws {
        do {
            try FileManager.default.createDirectory(
                at: eventSegmentsDirectoryURL,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let segment = EventSegment(
                version: EventSegment.currentVersion,
                sequence: sequence,
                event: event
            )
            let data = try encoder.encode(segment)
            let sequenceComponent = String(format: "%020llu", UInt64(sequence))
            let eventURL = eventSegmentsDirectoryURL
                .appendingPathComponent(
                    "\(sequenceComponent)-\(UUID().uuidString.lowercased())"
                )
                .appendingPathExtension("json")
            try data.write(to: eventURL, options: .atomic)
        } catch {
            throw UsageAnalyticsStoreError.persistenceFailed
        }
    }

    private func removeAppliedSegments(upTo watermark: Int) -> Bool {
        guard watermark > 0,
              FileManager.default.fileExists(atPath: eventSegmentsDirectoryURL.path)
        else { return false }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: eventSegmentsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return true }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var needsRetry = false
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let header = try? decoder.decode(SegmentHeader.self, from: data),
                  header.version == EventSegment.currentVersion,
                  let segment = try? decoder.decode(EventSegment.self, from: data),
                  segment.sequence > 0
            else { continue }
            guard segment.sequence <= watermark else {
                needsRetry = true
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                needsRetry = true
            }
        }
        return needsRetry
    }

    private func quarantineCorruptBaseArchive() throws -> URL {
        let recoveredURL = storageURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(storageURL.deletingPathExtension().lastPathComponent).corrupt-\(UUID().uuidString).json"
            )
        do {
            try FileManager.default.moveItem(at: storageURL, to: recoveredURL)
            archive = nil
            return recoveredURL
        } catch {
            throw UsageAnalyticsStoreError.persistenceFailed
        }
    }

    private func quarantineCorruptSegment(at url: URL) throws -> URL {
        let recoveredURL = eventSegmentsDirectoryURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(eventSegmentsDirectoryURL.lastPathComponent).corrupt-\(UUID().uuidString).json"
            )
        do {
            try FileManager.default.moveItem(at: url, to: recoveredURL)
            archive = nil
            return recoveredURL
        } catch {
            throw UsageAnalyticsStoreError.persistenceFailed
        }
    }

    @discardableResult
    private func mergeBackfill(
        events: [UsageEvent],
        coverage: UsageCoverageInterval?,
        into working: inout Archive
    ) -> Bool {
        var didChange = false
        for event in events where upsert(event, into: &working.events) {
            didChange = true
        }

        if let coverage {
            let mergedCoverage = mergeCoverage(working.coverage + [coverage])
            if mergedCoverage != working.coverage {
                working.coverage = mergedCoverage
                didChange = true
            }
        }
        return didChange
    }

    @discardableResult
    private func upsert(_ event: UsageEvent, into events: inout [UsageEvent]) -> Bool {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else {
            events.append(event)
            return true
        }

        let existing = events[index]
        var merged = event

        // Backfill can run repeatedly after live recording has begun. Preserve
        // exact dimensions independently so an estimated import cannot replace
        // exact cleanup counts just because it has better duration data, or vice
        // versa.
        if existing.cleanupQuality == .exact, event.cleanupQuality != .exact {
            merged.rawWordCount = existing.rawWordCount
            merged.finalWordCount = existing.finalWordCount
            merged.cleanupChanges = existing.cleanupChanges
            merged.cleanupQuality = existing.cleanupQuality
        }
        if durationRank(existing.durationQuality) > durationRank(event.durationQuality) {
            merged.durationMS = existing.durationMS
            merged.durationQuality = existing.durationQuality
        }
        guard merged != existing else { return false }
        events[index] = merged
        return true
    }

    private func durationRank(_ quality: UsageDurationQuality) -> Int {
        switch quality {
        case .captureExact:
            return 2
        case .transcriptEstimate:
            return 1
        case .unavailable:
            return 0
        }
    }

    private static func isSemanticallyValid(_ archive: Archive) -> Bool {
        guard archive.version == Archive.currentVersion,
              archive.appliedSegmentSequence >= 0,
              archive.events.allSatisfy(isSemanticallyValid),
              archive.coverage.allSatisfy(isSemanticallyValid)
        else {
            return false
        }
        return Set(archive.events.map(\.id)).count == archive.events.count
    }

    private static func isSemanticallyValid(_ interval: UsageCoverageInterval) -> Bool {
        guard let end = interval.end else { return true }
        return end >= interval.start
    }

    private static func isSemanticallyValid(_ event: UsageEvent) -> Bool {
        guard !event.appBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              event.appBundleID.utf8.count <= 1_024,
              (0...maximumStoredWordCount).contains(event.rawWordCount),
              (0...maximumStoredWordCount).contains(event.finalWordCount),
              (0...maximumStoredDurationMS).contains(event.durationMS)
        else {
            return false
        }

        let cleanupCounts = [
            event.cleanupChanges.fillerRemovals,
            event.cleanupChanges.lexiconCorrections,
            event.cleanupChanges.repairResolutions,
            event.cleanupChanges.structureRewrites,
            event.cleanupChanges.punctuationChanges,
            event.cleanupChanges.commandTransforms,
            event.cleanupChanges.estimatedWordChanges,
        ]
        guard cleanupCounts.allSatisfy({
            (0...maximumStoredCleanupCount).contains($0)
        }) else {
            return false
        }

        switch event.durationQuality {
        case .unavailable:
            guard event.durationMS == 0 else { return false }
        case .captureExact, .transcriptEstimate:
            guard event.durationMS > 0 else { return false }
        }

        switch event.cleanupQuality {
        case .exact:
            return event.cleanupChanges.estimatedWordChanges == 0
        case .estimated:
            return event.cleanupChanges.fillerRemovals == 0
                && event.cleanupChanges.lexiconCorrections == 0
                && event.cleanupChanges.repairResolutions == 0
                && event.cleanupChanges.structureRewrites == 0
                && event.cleanupChanges.punctuationChanges == 0
                && event.cleanupChanges.commandTransforms == 0
        }
    }

    private func mergeCoverage(_ intervals: [UsageCoverageInterval]) -> [UsageCoverageInterval] {
        let valid = intervals
            .filter { interval in
                guard let end = interval.end else { return true }
                return end >= interval.start
            }
            .sorted { $0.start < $1.start }
        guard var current = valid.first else { return [] }

        var merged: [UsageCoverageInterval] = []
        for next in valid.dropFirst() {
            if current.end == nil {
                continue
            }
            if let currentEnd = current.end, next.start <= currentEnd {
                if next.end == nil {
                    current.end = nil
                } else if let nextEnd = next.end, nextEnd > currentEnd {
                    current.end = nextEnd
                }
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }
}
