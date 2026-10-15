import Foundation
import Testing
@testable import StenoKit

@Suite("What cleanup changed, word by word")
struct CleanupChangeRecordTests {
    @Test("Removed fillers are listed as removals")
    func fillersRemoved() {
        let changes = CleanupChangeRecord.changes(
            from: "um so the meeting is uh at noon",
            to: "so the meeting is at noon"
        )
        #expect(changes == [
            CleanupChangeRecord(kind: "removed", before: "um", after: nil),
            CleanupChangeRecord(kind: "removed", before: "uh", after: nil),
        ])
    }

    @Test("Added punctuation is listed as an addition, not a changed word")
    func punctuationAdded() {
        let changes = CleanupChangeRecord.changes(
            from: "see you tomorrow thanks",
            to: "see you tomorrow, thanks."
        )
        #expect(changes == [
            CleanupChangeRecord(kind: "added", before: nil, after: ","),
            CleanupChangeRecord(kind: "added", before: nil, after: "."),
        ])
    }

    @Test("Corrected and capitalized words are listed as replacements")
    func wordsReplaced() {
        let changes = CleanupChangeRecord.changes(
            from: "open stenoh kit now",
            to: "Open StenoKit now"
        )
        #expect(changes == [
            CleanupChangeRecord(kind: "replaced", before: "open stenoh kit", after: "Open StenoKit"),
        ])
    }

    @Test("Spoken symbols are listed as the words they replaced")
    func spokenSymbolsReplaced() {
        let changes = CleanupChangeRecord.changes(
            from: "send it to bob at example dot com",
            to: "send it to bob@example.com"
        )
        #expect(changes == [
            CleanupChangeRecord(kind: "replaced", before: "at", after: "@"),
            CleanupChangeRecord(kind: "replaced", before: "dot", after: "."),
        ])
    }

    @Test("Identical text and whitespace-only changes record nothing")
    func nothingChanged() {
        #expect(CleanupChangeRecord.changes(from: "Hello there.", to: "Hello there.") == [])
        #expect(CleanupChangeRecord.changes(from: "Hello  there.\n", to: "Hello there.") == [])
    }

    @Test("The list and each side stay short")
    func bounded() {
        let raw = (0..<200).map { "um word\($0)" }.joined(separator: " ")
        let clean = (0..<200).map { "word\($0)" }.joined(separator: " ")
        let changes = CleanupChangeRecord.changes(from: raw, to: clean)
        #expect(changes?.count == CleanupChangeRecord.maximumCount)

        let long = String(repeating: "abcdefghij ", count: 30)
        let replaced = CleanupChangeRecord.changes(from: "x", to: long)
        let after = replaced?.first?.after ?? ""
        #expect(after.count == CleanupChangeRecord.maximumSideLength)
        #expect(after.hasSuffix("\u{2026}"))
    }

    @Test("Changes past the limit are counted though only the first are kept")
    func changesPastTheLimitAreCounted() {
        for trueCount in [CleanupChangeRecord.maximumCount, 30, 200] {
            let raw = (0..<trueCount).flatMap { ["um", "word\($0)"] }.joined(separator: " ")
            let clean = (0..<trueCount).map { "word\($0)" }.joined(separator: " ")
            let comparison = CleanupChangeRecord.compare(from: raw, to: clean)
            #expect(comparison.changeCount == trueCount)
            #expect(comparison.changes?.count == min(trueCount, CleanupChangeRecord.maximumCount))
            #expect(comparison.wasSkipped == false)
            #expect(comparison.changes == CleanupChangeRecord.changes(from: raw, to: clean))
        }
    }

    @Test("An unchanged dictation is compared with no changes, and a skipped one is told apart")
    func emptyAndSkippedComparisonsDiffer() {
        let same = CleanupChangeRecord.compare(from: "Same words.", to: "Same words.")
        #expect(same == CleanupChangeRecord.Comparison(changes: [], changeCount: 0))
        #expect(same.wasSkipped == false)

        let raw = (0..<9_000).map { "spoken\($0)" }.joined(separator: " ")
        let clean = (0..<9_000).map { "Written\($0)" }.joined(separator: " ")
        let skipped = CleanupChangeRecord.compare(from: raw, to: clean)
        #expect(skipped == CleanupChangeRecord.Comparison(changes: nil, changeCount: nil))
        #expect(skipped.wasSkipped)
    }

    @Test("Saved changes over the limits are trimmed when read")
    func decodedChangesAreBounded() throws {
        let side = String(repeating: "y", count: 200)
        let changes = (0..<(CleanupChangeRecord.maximumCount + 6)).map { _ in
            #"{"kind":"replaced","before":"\#(side)","after":"z"}"#
        }
        let json = #"{"schemaVersion":1,"cleanupChanges":["# + changes.joined(separator: ",") + "]}"
        let log = DecodingIssueLog()
        let record = try JSONDecoder.recordingIssues(to: log).decode(DictationRecord.self, from: Data(json.utf8))
        let decoded = try #require(record.cleanupChanges)
        #expect(decoded.count == CleanupChangeRecord.maximumCount)
        #expect(decoded.allSatisfy { $0.before?.count == CleanupChangeRecord.maximumSideLength && $0.after == "z" })
        #expect(log.replacedCount > 0)
    }

    @Test("A long dictation that differs throughout is not compared, so saving it isn't held up")
    func longDifferentInputIsSkipped() async {
        let raw = (0..<9_000).map { "spoken\($0)" }.joined(separator: " ")
        let clean = (0..<9_000).map { "Written\($0)" }.joined(separator: " ")
        #expect(CleanupChangeRecord.changes(from: raw, to: clean) == nil)

        // Skipping costs about what reading an unchanged dictation of the same
        // length costs; comparing 18,000 differing words first would cost
        // thousands of times more. Both run on this machine, so load cancels out.
        let ratio = await cpuTimeRatio(
            small: { _ = CleanupChangeRecord.changes(from: raw, to: raw) },
            large: { _ = CleanupChangeRecord.changes(from: raw, to: clean) }
        )
        #expect(ratio < 10, "skipping took \(ratio)x reading an unchanged dictation")
    }

    @Test("A long dictation with a few changes is still compared")
    func longSimilarInputIsCompared() {
        let words = (0..<9_000).map { "word\($0)" }
        var cleaned = words
        cleaned[4_500] = "Changed"
        let changes = CleanupChangeRecord.changes(from: words.joined(separator: " "), to: cleaned.joined(separator: " "))
        #expect(changes == [CleanupChangeRecord(kind: "replaced", before: "word4500", after: "Changed")])
    }

    @Test("The compared region stays within the limit")
    func limitIsOnTheChangedRegion() {
        let half = CleanupChangeRecord.maximumComparedTokens / 2
        let within = CleanupChangeRecord.changes(
            from: (0..<(half - 1)).map { "a\($0)" }.joined(separator: " "),
            to: (0..<(half - 1)).map { "b\($0)" }.joined(separator: " ")
        )
        #expect(within?.count == 1)
        let beyond = CleanupChangeRecord.changes(
            from: (0..<(half + 1)).map { "a\($0)" }.joined(separator: " "),
            to: (0..<(half + 1)).map { "b\($0)" }.joined(separator: " ")
        )
        #expect(beyond == nil)
    }
}
