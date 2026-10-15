import Foundation
import StenoKit
import Testing
@testable import Steno

/// A dictation whose paste was skipped because another app wrote to the clipboard (the island
/// says "Not pasted. Saved in History.") is Not Inserted in Today, the History list and filters,
/// and How It Was Written. It is never a copy.
@Suite("Dictation that was not pasted")
@MainActor
struct NotPastedDictationTests {
    /// What SessionCoordinator saves when another app writes to the clipboard before the paste
    /// keystroke: the record is built with the same naming functions the coordinator calls.
    private func notPastedEntry() throws -> TranscriptEntry {
        let result = InsertResult(
            status: .copiedOnly, method: .clipboardPaste, insertedText: "See you at four.",
            pasteAttempted: nil, copyReason: .clipboardChanged)
        // Setup preconditions: this is the exact insertion result the island words as not pasted.
        try #require(DictationResultPresentation.overlayResult(for: result, appName: "Mail") == .notPasted)
        let record = DictationRecord(
            schemaVersion: DictationRecord.currentSchemaVersion,
            outcome: DictationRecord.outcomeName(for: result),
            copyReason: DictationRecord.copyReasonName(for: result),
            recordingMS: 3_000, transcriptionMS: 800, cleanupMS: 5, insertionMS: 100,
            insertionMethod: DictationRecord.insertionMethodName(for: result),
            appName: "Mail", cleanupChanges: [])
        let entry = TranscriptEntry(
            appBundleID: "com.apple.mail", rawText: "see you at four", cleanText: "See you at four.",
            durationMS: 3_000, audioURL: nil, insertionStatus: result.status,
            pasteAttempted: result.pasteAttempted, record: record)
        try #require(entry.insertionStatus == .copiedOnly)
        try #require(!entry.wasPasted)
        try #require(entry.record?.outcome == "notPasted")
        try #require(entry.record?.copyReason == nil)
        return entry
    }

    /// A genuine copy (the app changed), as the coordinator records it.
    private func copiedEntry() throws -> TranscriptEntry {
        let result = InsertResult(
            status: .copiedOnly, method: .clipboardPaste, insertedText: "See you at four.",
            pasteAttempted: nil, copyReason: .appChanged)
        let record = DictationRecord(
            schemaVersion: DictationRecord.currentSchemaVersion,
            outcome: DictationRecord.outcomeName(for: result),
            copyReason: DictationRecord.copyReasonName(for: result),
            recordingMS: 3_000, transcriptionMS: 800, cleanupMS: 5, insertionMS: 100,
            insertionMethod: DictationRecord.insertionMethodName(for: result),
            appName: "Mail", cleanupChanges: [])
        let entry = TranscriptEntry(
            appBundleID: "com.apple.mail", rawText: "see you at four", cleanText: "See you at four.",
            durationMS: 3_000, audioURL: nil, insertionStatus: result.status,
            pasteAttempted: result.pasteAttempted, record: record)
        try #require(entry.record?.outcome == "copied")
        try #require(entry.record?.copyReason == "appChanged")
        return entry
    }

    @Test("Today words a dictation that was not pasted as a Not inserted note with Copy, not a Copied plate")
    func todayDoesNotSettleANotPastedDictationAsCopied() throws {
        let entry = try notPastedEntry()
        let resolution = GroveTodayFlow.resolve(entry, appName: "Mail")
        guard case .problem(let note) = resolution else {
            Issue.record("Today settled a plate instead of a note for a not-pasted dictation: \(resolution)")
            return
        }
        #expect(note.action == .copy)
        #expect(note.title == "Not inserted")
        #expect(note.message == "Saved in History. Copy the words and paste them where you need them.")
    }

    @Test("The list chip and reader header do not call a not-pasted dictation Copied")
    func chipDoesNotCallANotPastedDictationCopied() throws {
        let entry = try notPastedEntry()
        let texts = GroveRules.chips(for: entry).map(\.text)
        #expect(texts == ["Not inserted · Saved in History"], "chips were \(texts)")
        #expect(GroveRules.result(for: entry).text == "Not inserted")
    }

    @Test("A not-pasted dictation is listed under Not Inserted and not under Copied")
    func notPastedDictationBelongsUnderNotInserted() throws {
        let entry = try notPastedEntry()
        #expect(HistoryRules.entries([entry], matching: "", filter: .copied).isEmpty)
        #expect(HistoryRules.entries([entry], matching: "", filter: .notInserted).count == 1)
    }

    @Test("How it was written does not say a not-pasted dictation was copied to the clipboard")
    func howItWasWrittenDoesNotSayNotPastedWentToTheClipboard() throws {
        let entry = try notPastedEntry()
        let record = try #require(entry.record)
        let model = try #require(GroveHowItWasWritten.Model.make(entry: entry, record: record, appName: "Mail"))
        #expect(model.verb != "Copied", "the sentence verb was \(model.verb)")
        #expect(model.steps.last?.name != "Copied", "the last step was \(String(describing: model.steps.last))")
        let said = model.steps.map { "\($0.name) \($0.detail)" }.joined(separator: " ").lowercased()
        #expect(!said.contains("to the clipboard"), "steps said: \(said)")
        // The summary behind the section, too.
        let summary = WhatHappenedSummary.make(entry: entry, record: record, appName: "Mail")
        #expect(summary.rows.last?.step != "Copied")
        #expect(summary.rows.last?.detail.lowercased().contains("to the clipboard") != true)
    }

    @Test("Genuine copies and records-less 1.0.x copies still read Copied")
    func genuineCopiesStillReadCopied() throws {
        // A copy for a known reason keeps its reason.
        let copied = try copiedEntry()
        #expect(GroveRules.chips(for: copied).map(\.text) == ["Copied · App changed"])
        #expect(GroveTodayFlow.resolve(copied, appName: "Mail")
            == .settled(GroveOutcome(kind: .copied, title: "Copied · App changed", text: copied.displayText)))
        #expect(HistoryRules.entries([copied], matching: "", filter: .copied).count == 1)
        #expect(HistoryRules.entries([copied], matching: "", filter: .notInserted).isEmpty)
        // A 1.0.x entry has no record and a bare .copiedOnly status.
        let old = TranscriptEntry(appBundleID: "com.apple.mail", rawText: "a", cleanText: "A.", durationMS: 1_000,
                                  audioURL: nil, insertionStatus: .copiedOnly)
        #expect(GroveRules.chips(for: old).map(\.text) == ["Copied"])
        #expect(GroveTodayFlow.resolve(old, appName: "Mail")
            == .settled(GroveOutcome(kind: .copied, title: "Copied", text: old.displayText)))
        #expect(HistoryRules.entries([old], matching: "", filter: .copied).count == 1)
    }
}
