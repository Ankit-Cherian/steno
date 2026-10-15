import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

@Suite("Grove History rules")
@MainActor
struct GroveHistoryRulesTests {
    @Test("How it was written names the heard step and pairs each timed step with its wording")
    func steps() {
        let record = WindowSampleData.latestRecord
        let entry = WindowSampleData.entries()[0]
        let model = GroveHowItWasWritten.Model.make(entry: entry, record: record, appName: "Mail")
        #expect(model?.steps.map(\.name) == ["Heard", "Transcribed", "Cleaned up", "Inserted"])
        #expect(model?.steps.map(\.time) == ["12.0 s", "0.8 s", "under 0.1 s", "under 0.1 s"])
        #expect(model?.steps.map(\.detail) == ["MacBook Pro Microphone", "Small model", "Removed “um”, added a period", "Into Mail"])
    }

    @Test("The time after release is transcription, cleanup and insertion, never the recording")
    func afterRelease() {
        let record = WindowSampleData.latestRecord
        #expect(GroveHowItWasWritten.Model.millisecondsAfterRelease(record) == 910)
        #expect(GroveHowItWasWritten.Model.afterReleaseText(record) == "0.9 s")
        #expect(GroveHowItWasWritten.Model.timeText(40) == "under 0.1 s")
        #expect(GroveHowItWasWritten.Model.timeText(12_400) == "12.4 s")
        #expect(GroveHowItWasWritten.Model.timeText(59_940) == "59.9 s")
        #expect(GroveHowItWasWritten.Model.timeText(59_960) == "1 min")
        #expect(GroveHowItWasWritten.Model.timeText(241_000) == "4 min 1 s")
        #expect(GroveHowItWasWritten.Model.timeText(3_600_000) == "60 min")
        // A record that kept only the total uses it.
        #expect(GroveHowItWasWritten.Model.millisecondsAfterRelease(DictationRecord(endToEndMS: 1_300)) == 1_300)
        #expect(GroveHowItWasWritten.Model.millisecondsAfterRelease(DictationRecord()) == nil)
    }

    @Test("History's filter menu writes Not Inserted in title case, and deleting one says it can't be undone")
    func filterMenuTitles() {
        #expect(HistoryFilter.allCases.map(\.menuTitle) == ["All", "Inserted", "Copied", "Not Inserted"])
        #expect(HistoryRules.deleteOneMessage.hasSuffix("This can’t be undone."))
    }

    @Test("The sentence names what became of the text")
    func verb() {
        #expect(GroveHowItWasWritten.Model.verb(for: DictationRecord(insertionMethod: "typed")) == "Written")
        #expect(GroveHowItWasWritten.Model.verb(for: DictationRecord(outcome: "copied")) == "Copied")
        #expect(GroveHowItWasWritten.Model.verb(for: DictationRecord(outcome: "failed")) == "Transcribed")
    }

    @Test("A record without a timed step reads as saved before step records")
    func noTimings() {
        let entry = WindowSampleData.entries()[0]
        #expect(GroveHowItWasWritten.Model.make(entry: entry, record: DictationRecord(), appName: "Mail") == nil)
    }

    @Test("Cleanup is said in a few words")
    func cleanupWords() {
        func detail(_ changes: [CleanupChangeRecord]?) -> String {
            GroveHowItWasWritten.Model.cleanupDetail(DictationRecord(cleanupChanges: changes))
        }
        #expect(detail([]) == "No changes")
        #expect(detail([CleanupChangeRecord(kind: "removed", before: "um", after: nil)]) == "Removed “um”")
        let many = (0..<3).map { _ in CleanupChangeRecord(kind: "removed", before: "um", after: nil) }
        #expect(detail(many) == "3 changes")
    }

    @Test("A reader says the day when the dictation is not from today")
    func whenText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 12))!
        func entry(_ day: Int, _ hour: Int) -> TranscriptEntry {
            TranscriptEntry(createdAt: calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: 24))!,
                            appBundleID: "com.apple.mail", rawText: "a", cleanText: "a", durationMS: 1, audioURL: nil, insertionStatus: .inserted)
        }
        #expect(GroveEntryMeta.whenText(entry(7, 10), showsDay: true, now: now, calendar: calendar) == "10:24")
        #expect(GroveEntryMeta.whenText(entry(6, 17), showsDay: true, now: now, calendar: calendar) == "Yesterday, 17:24")
        #expect(GroveEntryMeta.whenText(entry(2, 9), showsDay: true, now: now, calendar: calendar).hasSuffix(", 09:24"))
        #expect(GroveEntryMeta.whenText(entry(2, 9), showsDay: false, now: now, calendar: calendar) == "09:24")
    }

    @Test("Long dictations are capped at 12 lines, short ones are not")
    func heroLimit() {
        #expect(GroveHero.lineLimit(for: String(repeating: "word ", count: 120)) == 12)
        #expect(GroveHero.lineLimit(for: "A sentence.") == nil)
        #expect(GroveHero.size(for: "A sentence.") == 22)
        #expect(GroveHero.size(for: String(repeating: "x", count: 300)) == 17)
        #expect(GroveHero.size(for: String(repeating: "x", count: 600)) == 15)
    }

    @Test("A capped text view ends at its line limit")
    func cappedLines() {
        let text = String(repeating: "The updated agenda goes to Dana before lunch. ", count: 30)
        let open = TranscriptMetrics(flowing: 15, measure: 592)
        let capped = TranscriptMetrics(flowing: 15, measure: 592, maxLines: 12)
        #expect(TranscriptLineCounter.lineCount(text, metrics: open) > 12)
        #expect(TranscriptLineCounter.lineCount(text, metrics: capped) == 12)
    }

    @Test("Show all lifts the line limit on a text view that was created capped")
    func showAllLiftsTheLimit() {
        let text = String(repeating: "The updated agenda goes to Dana before lunch. ", count: 30)
        let capped = TranscriptMetrics(flowing: 15, measure: 592, maxLines: 12)
        let open = TranscriptMetrics(flowing: 15, measure: 592)
        // The text view keeps its container across updates, as the reader and Today's card do.
        let storage = NSTextStorage(attributedString: TranscriptTypesetter.attributedString(text, metrics: capped, color: .black))
        let layout = NSLayoutManager()
        let container = TranscriptTypesetter.makeContainer(capped)
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        func laidOutLines() -> Int {
            layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
            layout.ensureLayout(for: container)
            var count = 0
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in count += 1 }
            return count
        }
        #expect(laidOutLines() == 12)
        TranscriptTypesetter.configure(container, open)
        #expect(laidOutLines() == TranscriptLineCounter.lineCount(text, metrics: open))
        #expect(layout.glyphRange(for: container).length == layout.numberOfGlyphs)
    }

    @Test("Around then offers the half hour before the sample's latest dictation, oldest first")
    func aroundThenSample() {
        let entries = WindowSampleData.entries()
        let latest = entries[0]
        let around = GroveRules.aroundThen(for: latest, in: entries)
        #expect(around.map(\.id) == [WindowSampleData.groceriesID])
        // The oldest dictation of the day has nothing before it.
        let booking = entries.first { $0.id == WindowSampleData.bookingID }!
        #expect(GroveRules.aroundThen(for: booking, in: entries).isEmpty)
    }

    @Test("The remembered Around then follows a new dictation and another selection")
    func aroundThenMemoFollowsChanges() {
        let memo = GroveAroundThenMemo()
        var entries = WindowSampleData.entries()
        let latest = entries[0]
        #expect(memo.around(latest, in: entries).map(\.id) == [WindowSampleData.groceriesID])
        #expect(memo.around(latest, in: entries).map(\.id) == [WindowSampleData.groceriesID])
        // A dictation said five minutes before the latest joins what was said around it.
        let added = TranscriptEntry(createdAt: latest.createdAt.addingTimeInterval(-300), appBundleID: "com.apple.Notes",
                                    rawText: "Ask about parking.", cleanText: "Ask about parking.", audioURL: nil,
                                    insertionStatus: .inserted)
        entries.insert(added, at: 1)
        #expect(memo.around(latest, in: entries).map(\.id) == GroveRules.aroundThen(for: latest, in: entries).map(\.id))
        #expect(memo.around(latest, in: entries).contains { $0.id == added.id })
        let booking = entries.first { $0.id == WindowSampleData.bookingID }!
        #expect(memo.around(booking, in: entries).isEmpty)
    }
}

/// Draws Grove's History in every state to PNG.
@Suite("Grove History renders", .serialized)
@MainActor
struct GroveHistoryRenderingTests {
    typealias Variant = GroveRenderHarness.Variant
    typealias Harness = GroveRenderHarness

    private static let danaFix = FixWordState(
        entryID: WindowSampleData.latestID,
        range: (WindowSampleData.latestText as NSString).range(of: "Dana"),
        word: "Dana", replacement: "Danna")

    /// The sample with a dictation 12 minutes before the latest, so Around then shows two cards.
    private func controller(_ variant: Variant, populated: Bool = true) -> DictationController {
        let controller = Harness.sampleController(variant, populated: populated)
        guard populated, let latest = controller.recentEntries.first else { return controller }
        let text = "Can you send me the venue address and the parking details before the weekend?"
        let earlier = TranscriptEntry(
            createdAt: latest.createdAt.addingTimeInterval(-12 * 60), appBundleID: "com.apple.MobileSMS",
            rawText: text, cleanText: text, durationMS: 8_000, audioURL: nil, insertionStatus: .inserted)
        controller.recentEntries.insert(earlier, at: 1)
        return controller
    }

    @Test("History with Around then", arguments: Variant.allCases)
    func withAroundThen(variant: Variant) async throws {
        let controller = controller(variant)
        try await Harness.write(ContentView(initialTab: .history, initialState: .init(historyEntryID: WindowSampleData.latestID)),
                                controller: controller, variant: variant, name: "history-around-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("History without Around then", arguments: [Variant.light, .dark])
    func withoutAroundThen(variant: Variant) async throws {
        let controller = controller(variant)
        try await Harness.write(ContentView(initialTab: .history, initialState: .init(historyEntryID: WindowSampleData.bookingID)),
                                controller: controller, variant: variant, name: "history-no-around-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("Before cleanup open", arguments: [Variant.light, .dark])
    func beforeCleanup(variant: Variant) async throws {
        let controller = controller(variant)
        var start = ContentView.InitialState(historyEntryID: WindowSampleData.latestID)
        start.historyBeforeCleanupExpanded = true
        try await Harness.write(ContentView(initialTab: .history, initialState: start), controller: controller, variant: variant,
                                name: "history-before-cleanup-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("Fix a word open", arguments: [Variant.light, .dark])
    func fixWord(variant: Variant) async throws {
        let controller = controller(variant)
        var start = ContentView.InitialState(historyEntryID: WindowSampleData.latestID)
        start.fix = Self.danaFix
        try await Harness.write(ContentView(initialTab: .history, initialState: start), controller: controller, variant: variant,
                                name: "history-fix-word-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("A fixed word, with its note")
    func fixed() async throws {
        let controller = controller(.light)
        if let index = controller.recentEntries.firstIndex(where: { $0.id == WindowSampleData.latestID }) {
            controller.recentEntries[index].cleanText = WindowSampleData.latestText.replacingOccurrences(of: "Dana", with: "Danna")
            controller.recentEntries[index].fixes = [
                WordFix(original: "Dana", replacement: "Danna", occurrence: 0, appliesToFuture: true, date: Date(), location: 78)
            ]
        }
        var start = ContentView.InitialState(historyEntryID: WindowSampleData.latestID)
        start.fixResult = FixWordResult(entryID: WindowSampleData.latestID, original: "Dana", replacement: "Danna",
                                        appliedToFuture: true, appName: "Mail")
        try await Harness.write(ContentView(initialTab: .history, initialState: start), controller: controller, variant: .light,
                                name: "history-fixed-light")
        await controller.teardownAndWait()
    }

    @Test("Search with matches, and without")
    func search() async throws {
        let controller = controller(.light)
        var start = ContentView.InitialState(historyEntryID: WindowSampleData.latestID)
        start.historyQuery = "agenda"
        try await Harness.write(ContentView(initialTab: .history, initialState: start), controller: controller, variant: .light,
                                name: "history-search-light")
        start.historyQuery = "Lisbonn"
        try await Harness.write(ContentView(initialTab: .history, initialState: start), controller: controller, variant: .light,
                                name: "history-search-empty-light")
        await controller.teardownAndWait()
    }

    @Test("A filter with nothing in it")
    func filterEmpty() async throws {
        let controller = controller(.light)
        controller.recentEntries.removeAll { $0.insertionStatus == .copiedOnly }
        var start = ContentView.InitialState(historyEntryID: WindowSampleData.latestID)
        start.historyFilter = .copied
        try await Harness.write(ContentView(initialTab: .history, initialState: start), controller: controller, variant: .light,
                                name: "history-filter-empty-light")
        await controller.teardownAndWait()
    }

    @Test("A dictation that was not inserted", arguments: [Variant.light, .dark])
    func notInserted(variant: Variant) async throws {
        let controller = controller(variant)
        try await Harness.write(ContentView(initialTab: .history, initialState: .init(historyEntryID: WindowSampleData.bookingID)),
                                controller: controller, variant: variant, name: "history-not-inserted-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("Cleanup ran again")
    func rerun() async throws {
        let controller = controller(.light)
        if let index = controller.recentEntries.firstIndex(where: { $0.id == WindowSampleData.latestID }) {
            controller.recentEntries[index].originalCleanText = WindowSampleData.latestText
            controller.recentEntries[index].cleanText = WindowSampleData.latestText.replacingOccurrences(of: "so everyone", with: "so that everyone")
        }
        try await Harness.write(ContentView(initialTab: .history, initialState: .init(historyEntryID: WindowSampleData.latestID)),
                                controller: controller, variant: .light, name: "history-rerun-light")
        await controller.teardownAndWait()
    }

    @Test("A dictation saved before step records")
    func noRecord() async throws {
        let controller = controller(.light)
        try await Harness.write(ContentView(initialTab: .history, initialState: .init(historyEntryID: WindowSampleData.contractID)),
                                controller: controller, variant: .light, name: "history-no-record-light")
        await controller.teardownAndWait()
    }

    @Test("A long dictation stops at 12 lines, and Show all opens it", arguments: [Variant.light, .dark])
    func longDictation(variant: Variant) async throws {
        let controller = controller(variant)
        let long = WindowSampleData.contract + " " + WindowSampleData.contract + " " + WindowSampleData.latestText + " " + WindowSampleData.contract
        if let index = controller.recentEntries.firstIndex(where: { $0.id == WindowSampleData.contractID }) {
            controller.recentEntries[index].cleanText = long
        }
        try await Harness.write(ContentView(initialTab: .history, initialState: .init(historyEntryID: WindowSampleData.contractID)),
                                controller: controller, variant: variant, name: "history-long-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("First run", arguments: [Variant.light, .dark])
    func firstRun(variant: Variant) async throws {
        let controller = controller(variant, populated: false)
        try await Harness.write(ContentView(initialTab: .history), controller: controller, variant: variant,
                                name: "history-first-run-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("The delete dialogs, drawn in the window", arguments: [Variant.light, .dark])
    func deleteDialogs(variant: Variant) async throws {
        let controller = controller(variant)
        let feedback = GroveFeedback()
        feedback.announce = { _ in }
        feedback.confirm(title: HistoryRules.deleteAllConfirmationTitle(listedCount: 412), message: HistoryRules.deleteAllMessage,
                         confirmTitle: HistoryRules.deleteAllButton) {}
        let view = Harness.window(.history, controller: controller, feedback: feedback) {
            GroveHistoryView(initialSelectedEntryID: WindowSampleData.latestID)
        }
        try await Harness.write(view, controller: controller, variant: variant, name: "history-delete-all-dialog-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("A note after Delete")
    func deletedNote() async throws {
        let controller = controller(.light)
        let feedback = GroveFeedback()
        feedback.announce = { _ in }
        feedback.post("Dictation deleted", systemImage: "trash")
        let view = Harness.window(.history, controller: controller, feedback: feedback) {
            GroveHistoryView(initialSelectedEntryID: WindowSampleData.latestID)
        }
        try await Harness.write(view, controller: controller, variant: .light, name: "history-deleted-note-light")
        await controller.teardownAndWait()
    }

    @Test("The minimum window")
    func minimum() async throws {
        let controller = controller(.light)
        try await Harness.write(ContentView(initialTab: .history, initialState: .init(historyEntryID: WindowSampleData.latestID)),
                                controller: controller, variant: .light, size: Harness.minimumSize, name: "history-minimum-light")
        await controller.teardownAndWait()
    }

    @Test("A large window")
    func large() async throws {
        let controller = controller(.dark)
        try await Harness.write(ContentView(initialTab: .history, initialState: .init(historyEntryID: WindowSampleData.latestID)),
                                controller: controller, variant: .dark, size: CGSize(width: 1440, height: 1000), name: "history-large-dark")
        await controller.teardownAndWait()
    }
}
