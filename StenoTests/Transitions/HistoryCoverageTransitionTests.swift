import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// The parts of History the first transition suite left out: Around then, How it was written,
/// Fix a Word in the reader's popover, Delete All, an empty filter, an empty History filling,
/// the list's keys and the window's shortcuts, and Copy.
@Suite("History coverage transitions", .serialized)
@MainActor
struct HistoryCoverageTransitionTests {
    typealias F = TransitionFixtures

    private func host(_ controller: DictationController, feedback: GroveFeedback = GroveFeedback(),
                      selected: UUID? = nil, query: SearchBox? = nil) -> TransitionHost {
        feedback.announce = { _ in }
        return TransitionHost(controller: controller) {
            GroveRenderHarness.window(.history, controller: controller, feedback: feedback) {
                if let query {
                    BoundSearchHistory(box: query, selected: selected)
                } else {
                    GroveHistoryView(initialSelectedEntryID: selected)
                }
            }
        }
    }

    private func readerText(_ host: TransitionHost) -> String? {
        host.transcriptViews().first?.textStorage?.string
    }

    private func rowNames(_ host: TransitionHost) -> [String] {
        guard let list = host.node(where: { $0.name == "Dictations" }) else { return [] }
        return host.nodes(under: list).filter { $0.role == "AXButton" }.map(\.name)
    }

    /// Buttons in the reader (outside the list) whose name starts with `prefix`.
    private func readerRows(_ host: TransitionHost, _ prefix: String) -> [TransitionHost.Node] {
        let listed = Set(host.nodes(under: host.node { $0.name == "Dictations" }).map { ObjectIdentifier($0.object) })
        return host.nodes().filter { $0.role == "AXButton" && $0.name.hasPrefix(prefix) && !listed.contains(ObjectIdentifier($0.object)) }
    }

    private func says(_ host: TransitionHost, _ prefix: String) -> Bool {
        host.node { $0.text.hasPrefix(prefix) } != nil
    }

    // MARK: Around then

    @Test("Around then lists the half hour before, oldest first, and a row opens that dictation even past a search")
    func aroundThenOpensADictation() async throws {
        let selected = F.entry("Confirm the venue for Thursday's offsite.", minutesAgo: 1)
        let five = F.entry("Ask Priya about the projector.", minutesAgo: 6)
        let twelve = F.entry("Order lunch for twelve people.", minutesAgo: 13)
        let old = F.entry("Water the plants on the balcony.", minutesAgo: 50)
        let controller = F.sampleController([selected, five, twelve, old])
        let query = SearchBox()
        let host = host(controller, selected: selected.id, query: query)
        defer { host.close() }
        await host.settle { readerText(host) != nil }

        #expect(says(host, "Around then"), "no Around then: \(host.names())")
        let around = readerRows(host, "")
            .filter { $0.name.hasPrefix("Ask Priya") || $0.name.hasPrefix("Order lunch") || $0.name.hasPrefix("Water the plants") }
        #expect(around.map { String($0.name.prefix(9)) } == ["Order lun", "Ask Priya"], "Around then lists \(around.map(\.name))")

        try await host.type("venue", into: "Search dictations")
        #expect(await host.settle { rowNames(host).count == 1 })
        let row = try #require(readerRows(host, "Order lunch").first, "Around then left with the search: \(host.names())")
        #expect(row.press())
        #expect(await host.settle { readerText(host) == GroveFlowText.displayText(twelve.cleanText) },
                "the reader shows \(readerText(host) ?? "nothing")")
        #expect(query.text.isEmpty, "the search stayed and hides the dictation now open")
        #expect(await host.settle { rowNames(host).count == 4 })
        let listRow = host.nodes(under: host.node { $0.name == "Dictations" }).first { $0.name.hasPrefix("Order lunch") }
        #expect(listRow?.isSelected == true, "the list does not mark the dictation Around then opened")
    }

    // MARK: How it was written

    @Test("How it was written names each recorded step, and says when an older dictation has none")
    func howItWasWritten() async throws {
        let controller = F.sampleController(WindowSampleData.entries())
        let host = host(controller, selected: WindowSampleData.latestID)
        defer { host.close() }
        await host.settle { host.node(named: "How it was written") != nil }
        let section = try #require(host.node(named: "How it was written"))
        let steps = host.nodes(under: section).map(\.name).filter { !$0.isEmpty }
        #expect(steps.contains { $0.hasPrefix("Heard, ") }, "steps: \(steps)")
        #expect(steps.count >= 3, "steps: \(steps)")

        try await host.pressRow(containing: "The parties agree", in: "Dictations")
        #expect(await host.settle { says(host, "How it was written") && host.node { $0.text.contains("didn’t record the steps") } != nil },
                "no note for an unrecorded dictation: \(host.names())")
    }

    // MARK: Fix a Word

    @Test("Fix a Word in the reader: the popover fixes the word, the reader redraws it, and Undo puts it back")
    func fixAWordInTheReader() async throws {
        let controller = F.sampleController(WindowSampleData.entries())
        let host = host(controller, selected: WindowSampleData.latestID)
        defer { host.close() }
        await host.settle { readerText(host) != nil }
        try await host.press("Fix a Word")
        #expect(await host.settle { says(host, "Select a word in the text to fix it.") }, "no hint: \(host.names())")
        let view = try #require(host.transcriptViews().first)
        #expect(await host.settle { (view.delegate as? TranscriptTextView.Coordinator)?.picksWord == true })
        let range = ((view.textStorage?.string ?? "") as NSString).range(of: "Dana")
        view.setSelectedRange(range)
        #expect(await host.settle { host.popoverWindows.contains { $0.contentView != nil } }, "no popover")
        try await host.type("Donna", into: "Correct spelling")
        await host.keyPress(36, characters: "\r")
        #expect(await host.settle { readerText(host)?.contains("Donna") == true }, "the reader says \(readerText(host) ?? "")")
        try await host.press("Undo")
        #expect(await host.settle { readerText(host)?.contains("Dana") == true && readerText(host)?.contains("Donna") == false })
    }

    @Test("Fix a Word on a common word asks first, and Fix This and Future Dictations then fixes it and adds the correction")
    func fixACommonWordAfterConfirming() async throws {
        let entry = F.entry("Send the plan to Dana.")
        let session = try await storedController([entry])
        defer { Task { await session.close() } }
        let feedback = GroveFeedback()
        let host = host(session.controller, feedback: feedback, selected: entry.id)
        defer { host.close() }
        await host.settle { readerText(host) != nil }
        try await host.press("Fix a Word")
        let view = try #require(host.transcriptViews().first)
        #expect(await host.settle { (view.delegate as? TranscriptTextView.Coordinator)?.picksWord == true })
        view.setSelectedRange(((view.textStorage?.string ?? "") as NSString).range(of: "the"))
        #expect(await host.settle { host.popoverWindows.contains { $0.contentView != nil } }, "no popover")
        try await host.type("a", into: "Correct spelling")
        try await host.press("This and future dictations")
        await host.keyPress(36, characters: "\r")
        #expect(await host.settle { feedback.dialog != nil }, "no question about the common word")
        #expect(feedback.dialog?.title == "\u{201C}the\u{201D} is a common word. Fix it in this and future dictations?")

        feedback.resolveDialog(confirmed: true)
        #expect(await host.settle { readerText(host)?.contains("Send a plan") == true },
                "after confirming, the reader says \(readerText(host) ?? "nothing")")
        #expect(session.controller.preferences.lexiconEntries.contains(LexiconEntry(term: "the", preferred: "a", scope: .global)),
                "no word correction for “the”")
    }

    // MARK: Delete All

    private func storedController(_ entries: [TranscriptEntry]) async throws -> WindowDictation {
        try await WindowDictation.make(entries: entries)
    }

    @Test("Delete All History asks with the count; Cancel keeps everything, Delete All empties the list and says so")
    func deleteAll() async throws {
        let session = try await storedController([F.entry(WindowSampleData.booking), F.entry(WindowSampleData.groceries, minutesAgo: 3)])
        defer { Task { await session.close() } }
        let feedback = GroveFeedback()
        let host = host(session.controller, feedback: feedback)
        defer { host.close() }
        await host.settle { rowNames(host).count == 2 }

        try await host.choose(menuItem: "Delete All History…")
        #expect(await host.settle { host.node(named: "Delete all 2 dictations?") != nil }, "no dialog: \(host.names())")
        try await host.press("Cancel")
        #expect(await host.settle { host.node(named: "Delete all 2 dictations?") == nil })
        #expect(rowNames(host).count == 2)

        try await host.choose(menuItem: "Delete All History…")
        #expect(await host.settle { host.node(named: HistoryRules.deleteAllButton) != nil })
        try await host.press(HistoryRules.deleteAllButton)
        #expect(await host.settle { says(host, "No dictations yet") }, "History did not empty: \(host.names())")
        #expect(says(host, "Nothing here yet"), "the reader still shows a dictation")
        #expect(await host.settle { feedback.notice?.text == "History deleted" })
    }

    // MARK: Filters and empty states

    @Test("A filter with nothing in it says so, and Show All brings every dictation back")
    func emptyFilterShowAll() async throws {
        let controller = F.sampleController([F.entry(WindowSampleData.latestText), F.entry(WindowSampleData.groceries, minutesAgo: 3)])
        let host = host(controller)
        defer { host.close() }
        await host.settle { rowNames(host).count == 2 }
        try await host.choose(menuItem: HistoryFilter.notInserted.menuTitle)
        #expect(await host.settle { says(host, "No dictations in “Not Inserted”") }, "\(host.names())")
        #expect(says(host, "No dictations to show"), "the reader kept a dictation the filter hides")
        try await host.press("Show All")
        #expect(await host.settle { rowNames(host).count == 2 })
        #expect(await host.settle { readerText(host) != nil })
    }

    @Test("An empty History says how it fills, and fills in place when the first dictation arrives")
    func emptyHistoryFills() async throws {
        let controller = F.sampleController([])
        let host = host(controller)
        defer { host.close() }
        #expect(await host.settle { says(host, "No dictations yet") && says(host, "Nothing here yet") }, "\(host.names())")

        let first = F.entry(WindowSampleData.booking)
        controller.recentEntries = [first]
        #expect(await host.settle { rowNames(host).count == 1 })
        #expect(await host.settle { readerText(host) == GroveFlowText.displayText(first.cleanText) }, "the reader stayed empty")
        #expect(!says(host, "No dictations yet"))
    }

    // MARK: Keys

    @Test("Down and Up move through the list, Delete asks to delete the selected one, and Esc keeps it")
    func listKeys() async throws {
        let entries = [F.entry(WindowSampleData.latestText), F.entry(WindowSampleData.groceries, minutesAgo: 2),
                       F.entry(WindowSampleData.booking, minutesAgo: 4)]
        let feedback = GroveFeedback()
        let host = host(F.sampleController(entries), feedback: feedback, selected: entries[0].id)
        defer { host.close() }
        await host.settle { readerText(host) != nil }
        try await host.pressRow(containing: "Move the planning", in: "Dictations")
        #expect(host.window.firstResponder is GroveKeyView, "the list did not take the keyboard")

        await host.key(125)
        #expect(await host.settle { readerText(host) == GroveFlowText.displayText(entries[1].cleanText) }, "Down did not move")
        await host.key(125)
        #expect(await host.settle { readerText(host) == GroveFlowText.displayText(entries[2].cleanText) })
        await host.key(125)
        #expect(readerText(host) == GroveFlowText.displayText(entries[2].cleanText), "Down moved past the last")
        await host.key(126)
        #expect(await host.settle { readerText(host) == GroveFlowText.displayText(entries[1].cleanText) }, "Up did not move")

        await host.key(51)
        #expect(await host.settle { host.node(named: HistoryRules.deleteOneTitle) != nil }, "Delete did not ask: \(host.names())")
        await host.keyPress(53, characters: "\u{1B}")
        #expect(await host.settle { host.node(named: HistoryRules.deleteOneTitle) == nil }, "Esc left the dialog")
        #expect(rowNames(host).count == 3)
    }

    @Test("⌘F puts the caret in the search, ⌘E starts Fix a Word, and ⌘I brings How it was written into view")
    func commandKeys() async throws {
        let text = F.longText + " " + F.longText
        let long = TranscriptEntry(appBundleID: "com.apple.mail", rawText: text, cleanText: text,
                                   audioURL: nil, insertionStatus: .inserted, record: WindowSampleData.latestRecord)
        let host = host(F.sampleController([long]), selected: long.id)
        defer { host.close() }
        await host.settle { readerText(host) != nil }
        // Every word open, so How it was written is below the reader's fold.
        try await host.press(prefix: "Show All ")
        host.window.makeKey()

        await host.keyPress(3, characters: "f", modifiers: .command)
        let field = host.views(NSTextField.self).first { $0.accessibilityLabel() == "Search dictations" }
        #expect(await host.settle { (host.window.firstResponder as? NSTextView)?.delegate === field },
                "⌘F did not focus the search: \(String(describing: host.window.firstResponder))")

        await host.keyPress(14, characters: "e", modifiers: .command)
        #expect(await host.settle { says(host, "Select a word in the text to fix it.") }, "⌘E did not start Fix a Word")

        let window = host.window.frame
        let before = try #require(host.node(named: "How it was written")).screenFrame
        #expect(!window.intersects(before), "the fixture already shows How it was written at \(before) in \(window)")
        await host.keyPress(34, characters: "i", modifiers: .command)
        #expect(await host.settle { host.node(named: "How it was written").map { window.contains($0.screenFrame.insetBy(dx: 2, dy: 2)) } ?? false },
                "⌘I left How it was written at \(host.node(named: "How it was written")?.screenFrame ?? .zero) outside \(window)")
    }

    @Test("⌘E after choosing a row in History's list fixes a word in that dictation")
    func commandEFollowsTheChosenRow() async throws {
        let first = F.entry("Please send the report before lunch.", minutesAgo: 1)
        let second = F.entry("Move the meeting to Friday afternoon.", minutesAgo: 2)
        let host = host(F.sampleController([first, second]), selected: second.id)
        defer { host.close() }
        await host.settle { readerText(host)?.contains("Friday") == true }
        try await host.pressRow(containing: "Please send", in: "Dictations")
        #expect(await host.settle { readerText(host)?.contains("Please send") == true })
        host.window.makeKey()
        await host.keyPress(14, characters: "e", modifiers: .command)
        #expect(await host.settle { says(host, "Select a word in the text to fix it.") }, "⌘E did not start Fix a Word")
        #expect(readerText(host)?.contains("Please send") == true, "⌘E moved the selection back to the first dictation")
    }

    @Test("⌘I after choosing a row in History's list shows how that dictation was written")
    func commandIFollowsTheChosenRow() async throws {
        var first = F.entry("Please send the report before lunch. " + F.longText + " " + F.longText, minutesAgo: 1)
        first.record = WindowSampleData.latestRecord
        let second = F.entry("Move the meeting to Friday afternoon.", minutesAgo: 2)
        let host = host(F.sampleController([first, second]), selected: second.id)
        defer { host.close() }
        await host.settle { readerText(host)?.contains("Friday") == true }
        try await host.pressRow(containing: "Please send", in: "Dictations")
        #expect(await host.settle { readerText(host)?.contains("Please send") == true })
        // Every word open, so How it was written is below the reader's fold.
        try await host.press(prefix: "Show All ")
        let window = host.window.frame
        let before = try #require(host.node(named: "How it was written")).screenFrame
        #expect(!window.intersects(before), "the fixture already shows How it was written at \(before) in \(window)")
        host.window.makeKey()
        await host.keyPress(34, characters: "i", modifiers: .command)
        #expect(await host.settle { host.node(named: "How it was written").map { window.contains($0.screenFrame.insetBy(dx: 2, dy: 2)) } ?? false },
                "⌘I left How it was written outside the window")
        #expect(readerText(host)?.contains("Please send") == true, "⌘I moved the selection back to the first dictation")
    }

    // MARK: VoiceOver

    @Test("VoiceOver reads the reader's words as text, keeps Copy, Fix a Word… and Delete, and reads a password field's words too")
    func readerWordsReachVoiceOver() async throws {
        let words = F.entry("Move the meeting to Friday afternoon.", minutesAgo: 1)
        var secret = F.entry("Hunter two is the guest network name.", minutesAgo: 2)
        secret.concealedCopy = true
        let host = host(F.sampleController([words, secret]), selected: words.id)
        defer { host.close() }
        await host.settle { readerText(host)?.contains("Friday") == true }

        func dictation() -> TransitionHost.Node? { host.node { $0.customActionNames.contains("Copy") } }
        let element = try #require(dictation(), "no dictation element: \(host.names())")
        #expect(element.role == "AXStaticText", "the words are a \(element.role)")
        #expect(element.value.contains("Move the meeting to Friday afternoon."), "VoiceOver reads “\(element.value)”")
        #expect(element.name == AppNames.name(for: words))
        #expect(Set(["Copy", "Fix a Word…", "Delete"]).isSubset(of: element.customActionNames), "actions: \(element.customActionNames)")

        try await host.pressRow(containing: "Hunter two", in: "Dictations")
        #expect(await host.settle { dictation()?.value.contains("Hunter two is the guest network name.") == true },
                "a password field's words read “\(dictation()?.value ?? "nothing")”")
    }

    // MARK: Copy

    @Test("Copy in the reader puts the words on the clipboard and says so")
    func copyFromTheReader() async throws {
        let entry = F.entry(WindowSampleData.booking)
        let session = try await WindowDictation.make(entries: [entry])
        defer { Task { await session.close() } }
        let feedback = GroveFeedback()
        let host = host(session.controller, feedback: feedback, selected: entry.id)
        defer { host.close() }
        await host.settle { readerText(host) != nil }
        try await host.press("Copy")
        var copied = ""
        for _ in 0..<12_000 where copied != entry.cleanText {
            copied = await session.clipboard.latestValue
            await host.pump(.milliseconds(10))
        }
        #expect(copied == entry.cleanText)
        #expect(await host.settle { feedback.notice?.text == "Copied to the clipboard" })
    }
}

/// History with its search bound to a box the test reads.
private struct BoundSearchHistory: View {
    @ObservedObject var box: SearchBox
    let selected: UUID?

    var body: some View {
        GroveHistoryView(searchQuery: $box.text, initialSelectedEntryID: selected)
    }
}
