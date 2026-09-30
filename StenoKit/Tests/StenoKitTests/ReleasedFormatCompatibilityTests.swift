import Foundation
import Testing
@testable import StenoKit

/// Copies of the data types exactly as the published 1.0.0 release decodes
/// them: synthesized `Codable`, every listed key required, and enums that
/// reject unknown values. Files this version writes must decode with them,
/// because 1.0.0 discards a whole file it can't decode.
enum Released100 {
    enum InsertionStatus: String, Codable {
        case inserted
        case copiedOnly
        case failed
        case noSpeech
    }

    struct TranscriptEntry: Codable {
        var id: UUID
        var createdAt: Date
        var appBundleID: String
        var rawText: String
        var cleanText: String
        var durationMS: Int
        var audioURL: URL?
        var insertionStatus: InsertionStatus
    }

    enum UsageDurationQuality: String, Codable {
        case captureExact
        case transcriptEstimate
        case unavailable
    }

    enum UsageMetricQuality: String, Codable {
        case exact
        case estimated
    }

    struct UsageCleanupBreakdown: Codable {
        var fillerRemovals: Int
        var lexiconCorrections: Int
        var repairResolutions: Int
        var structureRewrites: Int
        var punctuationChanges: Int
        var commandTransforms: Int
        var estimatedWordChanges: Int
    }

    struct UsageEvent: Codable {
        var id: UUID
        var createdAt: Date
        var appBundleID: String
        var rawWordCount: Int
        var finalWordCount: Int
        var durationMS: Int
        var durationQuality: UsageDurationQuality
        var cleanupChanges: UsageCleanupBreakdown
        var cleanupQuality: UsageMetricQuality
        var insertionStatus: InsertionStatus
    }

    struct UsageCoverageInterval: Codable {
        var start: Date
        var end: Date?
    }

    struct UsageArchive: Codable {
        var version: Int
        var events: [UsageEvent]
        var coverage: [UsageCoverageInterval]
        var appliedSegmentSequence: Int
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@Suite("Files written by this version load in 1.0.0")
struct ReleasedFormatCompatibilityTests {
    @Test("History rewritten after a partly readable load decodes with the 1.0.0 types")
    func historyAfterRecoveryDecodesInReleasedVersion() async throws {
        let fixture = try HistoryFixture(entryCount: 40)
        defer { fixture.cleanUp() }
        _ = try fixture.writeDamaged(.unknownInsertionStatus)

        let store = fixture.store()
        try await store.append(entry: HistoryFixture.entry("Written by this version"))

        let released = try Released100.decoder().decode(
            [Released100.TranscriptEntry].self,
            from: Data(contentsOf: fixture.storageURL)
        )
        #expect(released.count == 41)
        #expect(released.first(where: { $0.id == fixture.damagedEntryID })?.insertionStatus == .copiedOnly)
    }

    @Test("History moved aside and restarted decodes with the 1.0.0 types")
    func historyAfterMoveAsideDecodesInReleasedVersion() async throws {
        let fixture = try HistoryFixture(entryCount: 10)
        defer { fixture.cleanUp() }
        _ = try fixture.writeDamaged(.truncatedJSON)

        let store = fixture.store()
        try await store.append(entry: HistoryFixture.entry("Fresh start"))

        let released = try Released100.decoder().decode(
            [Released100.TranscriptEntry].self,
            from: Data(contentsOf: fixture.storageURL)
        )
        #expect(released.map(\.rawText) == ["Fresh start"])
    }
}
