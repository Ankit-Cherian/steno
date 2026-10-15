import Foundation
import StenoKit
import Testing
@testable import Steno

/// How It Was Written words what cleanup changed honestly: a list cut at the limit is counted in
/// full, a comparison that was skipped is not "No changes", and records written before the count
/// was kept keep their wording.
@Suite("Cleanup change wording")
@MainActor
struct CleanupChangeWordingTests {
    /// The record SessionCoordinator saves for a dictation cleaned from `raw` to `clean`.
    private func record(from raw: String, to clean: String) -> DictationRecord {
        let comparison = CleanupChangeRecord.compare(from: raw, to: clean)
        return DictationRecord(
            recordingMS: 1_000, transcriptionMS: 100, cleanupMS: 10, insertionMS: 10,
            insertionMethod: "typed", cleanupChanges: comparison.changes,
            cleanupChangeCount: comparison.changeCount,
            cleanupComparisonSkipped: comparison.wasSkipped ? true : nil)
    }

    private func cleanedUpDetail(_ record: DictationRecord) throws -> String {
        let model = try #require(GroveHowItWasWritten.Model.make(
            entry: WindowSampleData.entries()[0], record: record, appName: "Mail"))
        return try #require(model.steps.first { $0.name == "Cleaned up" }).detail
    }

    /// `count` fillers, each removed in front of its own word.
    private func fillerDictation(count: Int) -> (raw: String, clean: String) {
        let raw = (0..<count).flatMap { ["um", "w\($0)"] }.joined(separator: " ")
        let clean = (0..<count).map { "w\($0)" }.joined(separator: " ")
        return (raw, clean)
    }

    @Test("A cleanup list cut at the limit is worded with the full number of changes")
    func cappedCleanupListIsWordedWithTheFullCount() throws {
        for trueCount in [30, 200] {
            let (raw, clean) = fillerDictation(count: trueCount)
            let record = record(from: raw, to: clean)
            // Setup preconditions: the list is cut at the limit, and the record holds the real count.
            try #require(record.cleanupChanges?.count == CleanupChangeRecord.maximumCount)
            try #require(record.cleanupChangeCount == trueCount)
            #expect(try cleanedUpDetail(record) == "\(trueCount) changes")
            #expect(WhatHappenedSummary.cleanupDetail(record).hasPrefix("\(trueCount) changes: "))
        }
    }

    @Test("A skipped cleanup comparison is worded as not compared")
    func skippedCleanupComparisonIsWordedAsNotCompared() throws {
        let words = (0..<1_600).map { "w\($0)" }
        let joined = words.joined(separator: " ")
        let inputs: [(raw: String, clean: String)] = [
            // Fillers at both ends.
            (raw: "um " + joined + " um", clean: joined),
            // First and last word recased.
            (raw: "a " + joined + " z", clean: "A " + joined + " Z"),
        ]
        for (raw, clean) in inputs {
            // Setup preconditions: cleanup visibly rewrote the text, and the comparison was skipped.
            try #require(raw != clean)
            let record = record(from: raw, to: clean)
            try #require(record.cleanupChanges == nil)
            #expect(try cleanedUpDetail(record) == "Not compared")
            #expect(WhatHappenedSummary.cleanupDetail(record) == "not compared")
        }
    }

    @Test("Exact counts, named changes and a real empty comparison keep their wording")
    func exactCleanupWordingStillHolds() throws {
        let (raw, clean) = fillerDictation(count: 20)
        let twenty = record(from: raw, to: clean)
        try #require(twenty.cleanupChangeCount == 20)
        #expect(try cleanedUpDetail(twenty) == "20 changes")

        let unchanged = record(from: "Same words.", to: "Same words.")
        try #require(unchanged.cleanupChanges == [])
        #expect(try cleanedUpDetail(unchanged) == "No changes")
        #expect(WhatHappenedSummary.cleanupDetail(unchanged) == "no changes")

        let one = record(from: "um so it works", to: "so it works")
        #expect(try cleanedUpDetail(one) == "Removed “um”")
        let two = record(from: "um so it works uh", to: "so it works")
        #expect(try cleanedUpDetail(two) == "Removed “um”, removed “uh”")
    }

    @Test("A record saved before the change count was kept keeps its wording")
    func recordsWithoutTheCountKeepTheirWording() throws {
        let removals = (0..<24).map { _ in CleanupChangeRecord(kind: "removed", before: "um", after: nil) }
        let full = DictationRecord(
            recordingMS: 1_000, transcriptionMS: 100, cleanupMS: 10, insertionMS: 10,
            insertionMethod: "typed", cleanupChanges: removals)
        #expect(try cleanedUpDetail(full) == "24 changes")
        let none = DictationRecord(
            recordingMS: 1_000, transcriptionMS: 100, cleanupMS: 10, insertionMS: 10,
            insertionMethod: "typed", cleanupChanges: nil)
        #expect(try cleanedUpDetail(none) == "No changes")
    }
}
