import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// History driven through its own controls on a live window: the reader follows the selection,
/// Show all opens the whole dictation and resets for the next one, and search, the filter and
/// the per-dictation actions all land in what is drawn.
@Suite("History transitions", .serialized)
@MainActor
struct HistoryTransitionTests {
    typealias F = TransitionFixtures

    private func host(_ controller: DictationController, feedback: GroveFeedback = GroveFeedback(),
                      selected: UUID? = nil) -> TransitionHost {
        TransitionHost(controller: controller) {
            GroveRenderHarness.window(.history, controller: controller, feedback: feedback) {
                GroveHistoryView(initialSelectedEntryID: selected)
            }
        }
    }

    /// The reader's dictation text as drawn.
    private func readerText(_ host: TransitionHost) -> String? {
        host.transcriptViews().first?.textStorage?.string
    }

    /// The rows of the list, by the start of their text.
    private func rowNames(_ host: TransitionHost) -> [String] {
        guard let list = host.node(where: { $0.name == "Dictations" }) else { return [] }
        return host.nodes(under: list).filter { $0.role == "AXButton" }.map(\.name)
    }

    @Test("Show all draws every word of a long dictation, and Show fewer cuts it again")
    func showAllDrawsEveryWord() async throws {
        let long = F.entry(F.longText)
        let controller = F.sampleController([long, F.entry(WindowSampleData.groceries, minutesAgo: 5)])
        let host = host(controller, selected: long.id)
        defer { host.close() }
        await host.settle { host.transcriptViews().first != nil }

        let capped = DrawnText(try #require(host.transcriptViews().first))
        #expect(capped.lines == 12)
        #expect(capped.isTruncated)
        #expect(!capped.showsWholeText)

        try await host.press(prefix: "Show All ")
        #expect(await host.settle { host.transcriptViews().first.map { DrawnText($0).lines > 12 } ?? false })
        let view = try #require(host.transcriptViews().first)
        let open = DrawnText(view)
        #expect(open.showsWholeText, "Show all left words undrawn: \(open)")
        let metrics = try #require(view.signature?.metrics)
        #expect(open.lines == TranscriptLineCounter.lineCount(GroveFlowText.displayText(F.longText), metrics: metrics))

        try await host.press("Show Fewer Words")
        #expect(await host.settle { host.transcriptViews().first.map { DrawnText($0).lines == 12 } ?? false })
        #expect(DrawnText(try #require(host.transcriptViews().first)).isTruncated)
        #expect(host.node { $0.name.hasPrefix("Show All ") } != nil)
    }

    @Test("Show all is offered only when the 12-line limit cuts words, not for a long text that fits")
    func showAllOnlyWhenCut() async throws {
        let fits = "Open this link before the call and leave your comments on the closing date: \(WindowSampleData.unbreakableToken) "
            + "It has every revision since Monday, and the comments from their counsel are in the second tab. Read the notes "
            + "on the escrow letter as well, because they change the deposit schedule."
        #expect(fits.count > 500, "the text is past the character count that sets the limit")
        let entry = F.entry(fits)
        let host = host(F.sampleController([entry]), selected: entry.id)
        defer { host.close() }
        #expect(await host.settle { readerText(host) != nil })
        let words = DrawnText(try #require(host.transcriptViews().first))
        #expect(words.lines < 12 && words.showsWholeText, "the text was meant to fit: \(words)")
        #expect(host.node { $0.name.hasPrefix("Show All") } == nil, "Show All offered for a text that is not cut: \(host.names())")
    }

    @Test("Choosing another dictation redraws the reader with its words, and Show all starts closed for it")
    func selectionUpdatesTheReader() async throws {
        let first = F.entry(F.longText)
        let second = F.entry(F.longText.replacingOccurrences(of: "Dana", with: "Priya"), minutesAgo: 3)
        let short = F.entry(WindowSampleData.groceries, minutesAgo: 6)
        let controller = F.sampleController([first, second, short])
        let host = host(controller, selected: first.id)
        defer { host.close() }
        await host.settle { readerText(host) != nil }
        #expect(readerText(host) == GroveFlowText.displayText(first.cleanText))

        try await host.press(prefix: "Show All ")
        #expect(await host.settle { host.transcriptViews().first.map { DrawnText($0).showsWholeText } ?? false })

        try await host.pressRow(containing: "Priya", in: "Dictations")
        #expect(await host.settle { readerText(host) == GroveFlowText.displayText(second.cleanText) },
                "the reader still shows \(readerText(host)?.prefix(60) ?? "nothing")")
        let drawn = DrawnText(try #require(host.transcriptViews().first))
        #expect(drawn.isTruncated && drawn.lines == 12, "Show all carried over to another dictation")
        #expect(host.node { $0.name.hasPrefix("Show All ") } != nil)
        #expect(host.node(named: "Show Fewer Words") == nil)

        try await host.pressRow(containing: "Pick up tomatoes", in: "Dictations")
        #expect(await host.settle { readerText(host) == GroveFlowText.displayText(short.cleanText) })
        #expect(DrawnText(try #require(host.transcriptViews().first)).showsWholeText)
        #expect(host.node { $0.name.hasPrefix("Show All ") } == nil, "a short dictation has no Show all")
        let list = host.node { $0.name == "Dictations" }
        let row = try #require(host.nodes(under: list).first { $0.name.hasPrefix("Pick up tomatoes") })
        #expect(row.isSelected, "the list marks the dictation the reader shows")
    }

    @Test("Before cleanup opens the words as spoken and closes again, and resets for the next dictation")
    func beforeCleanupExpandsAndCollapses() async throws {
        let cleaned = F.entry("Move the meeting to Friday.", raw: "Um, move the meeting to Friday")
        let other = F.entry(WindowSampleData.groceries, minutesAgo: 4, raw: "uh " + WindowSampleData.groceries)
        let controller = F.sampleController([cleaned, other])
        let host = host(controller, selected: cleaned.id)
        defer { host.close() }
        await host.settle { host.node(named: "Before cleanup") != nil }
        let legend = { host.node { $0.text.hasPrefix("Cleanup removed") || $0.text.hasPrefix("Cleanup added")
            || $0.text.hasPrefix("Cleanup changed") } }
        #expect(legend() == nil)

        try await host.press("Before cleanup")
        #expect(await host.settle { legend() != nil }, "Before cleanup did not open: \(host.names())")
        #expect(host.node(named: "Before cleanup")?.isSelected == true)

        try await host.press("Before cleanup")
        #expect(await host.settle { legend() == nil }, "Before cleanup did not close")

        try await host.press("Before cleanup")
        #expect(await host.settle { legend() != nil })
        try await host.pressRow(containing: "Pick up tomatoes", in: "Dictations")
        #expect(await host.settle { readerText(host) == GroveFlowText.displayText(other.cleanText) })
        #expect(legend() == nil, "Before cleanup stayed open for another dictation")
    }

    @Test("Typing a search filters the list as each letter lands, and clearing it brings every dictation back")
    func searchFiltersLiveAndClears() async throws {
        let entries = [F.entry(WindowSampleData.latestText), F.entry(WindowSampleData.groceries, minutesAgo: 2),
                       F.entry(WindowSampleData.booking, minutesAgo: 4)]
        let controller = F.sampleController(entries)
        let query = SearchBox()
        let host = TransitionHost(controller: controller) {
            GroveRenderHarness.window(.history, controller: controller) {
                SearchingHistory(box: query, selected: entries[0].id)
            }
        }
        defer { host.close() }
        await host.settle { rowNames(host).count == 3 }

        try await host.type("tom", into: "Search dictations")
        #expect(query.text == "tom")
        #expect(await host.settle { rowNames(host).count == 1 }, "rows: \(rowNames(host))")
        #expect(rowNames(host).first?.hasPrefix("Pick up tomatoes") == true)
        #expect(host.node { $0.text.contains("1 dictation matches") } != nil)
        // The reader follows: the dictation it showed is no longer listed.
        #expect(await host.settle { readerText(host) == GroveFlowText.displayText(WindowSampleData.groceries) })
        #expect(host.transcriptViews().first?.signature?.marks.highlights.isEmpty == false, "the match is not marked")

        try await host.type("xyz", into: "Search dictations")
        #expect(await host.settle { rowNames(host).isEmpty })
        #expect(host.node(named: "Clear Search") != nil)

        try await host.press("Clear search")
        #expect(query.text.isEmpty)
        #expect(await host.settle { rowNames(host).count == 3 }, "rows: \(rowNames(host))")
        #expect(host.transcriptViews().first?.signature?.marks.highlights.isEmpty == true, "an old match is still marked")
    }

    @Test("The filter menu narrows the list, shows its name, and All brings everything back")
    func filterMenu() async throws {
        let inserted = F.entry(WindowSampleData.latestText)
        let failed = F.entry(WindowSampleData.booking, minutesAgo: 3, status: .failed)
        let copied = F.entry(WindowSampleData.groceries, minutesAgo: 5, status: .copiedOnly)
        let controller = F.sampleController([inserted, failed, copied])
        let host = host(controller, selected: inserted.id)
        defer { host.close() }
        await host.settle { rowNames(host).count == 3 }

        try await host.choose(menuItem: HistoryFilter.notInserted.menuTitle)
        #expect(await host.settle { rowNames(host).count == 1 }, "rows: \(rowNames(host))")
        #expect(rowNames(host).first?.hasPrefix("Book a table") == true)
        #expect(await host.settle { readerText(host) == GroveFlowText.displayText(failed.cleanText) })
        #expect(host.node(identifier: "history.filter")?.value == HistoryFilter.notInserted.menuTitle)

        try await host.choose(menuItem: HistoryFilter.all.menuTitle)
        #expect(await host.settle { rowNames(host).count == 3 }, "rows: \(rowNames(host))")
        #expect(await host.settle { host.node(identifier: "history.filter") == nil }, "the filter's name stayed after All")
    }

    // MARK: Actions that change History

    /// A controller with its own History file in a temporary folder, so delete and cleanup
    /// really run. The isolated preview controller keeps those as no-ops.
    private func storedController(_ entries: [TranscriptEntry]) async throws -> (DictationController, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StenoTransitions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = HistoryStore(storageURL: directory.appendingPathComponent("history.json"))
        for entry in entries.reversed() { try await store.append(entry: entry) }
        let controller = makeTestDictationController(hotkey: TransitionHotkey(), historyStore: store,
                                                     legacyHistoryURL: directory.appendingPathComponent("legacy.json"))
        await controller.refreshHistory()
        return (controller, directory)
    }

    @Test("Delete asks first: Cancel keeps the dictation, Delete removes it and the reader moves on")
    func deleteConfirmAndCancel() async throws {
        let doomed = F.entry(WindowSampleData.booking)
        let kept = F.entry(WindowSampleData.groceries, minutesAgo: 3)
        let (controller, directory) = try await storedController([doomed, kept])
        defer { controller.teardown(); try? FileManager.default.removeItem(at: directory) }
        let feedback = GroveFeedback()
        feedback.announce = { _ in }
        let host = host(controller, feedback: feedback, selected: doomed.id)
        defer { host.close() }
        await host.settle { readerText(host) == GroveFlowText.displayText(doomed.cleanText) }

        try await host.press("Delete")
        #expect(await host.settle { host.node(named: HistoryRules.deleteOneTitle) != nil }, "no confirmation: \(host.names())")
        try await host.press("Cancel")
        #expect(await host.settle { host.node(named: HistoryRules.deleteOneTitle) == nil })
        #expect(rowNames(host).count == 2)
        #expect(readerText(host) == GroveFlowText.displayText(doomed.cleanText))

        try await host.press("Delete")
        #expect(await host.settle { host.node(named: HistoryRules.deleteOneTitle) != nil })
        let confirm = try #require(host.nodes(named: HistoryRules.deleteOneButton).last)
        #expect(confirm.press())
        #expect(await host.settle { rowNames(host).count == 1 }, "rows: \(rowNames(host))")
        #expect(host.node(named: HistoryRules.deleteOneTitle) == nil)
        #expect(await host.settle { readerText(host) == GroveFlowText.displayText(kept.cleanText) },
                "the reader still shows the deleted dictation")
        #expect(await host.settle { feedback.notice?.text == "Dictation deleted" })
    }

    @Test("Clean Up Again rewrites the words in place with a note, and Restore puts the original back")
    func cleanUpAgainAndRestore() async throws {
        let notes = TranscriptEntry(appBundleID: "com.apple.Notes", rawText: "open stenoh now", cleanText: "open stenoh now",
                                    audioURL: nil, insertionStatus: .inserted)
        let (controller, directory) = try await storedController([notes])
        defer { controller.teardown(); try? FileManager.default.removeItem(at: directory) }
        let host = host(controller, selected: notes.id)
        defer { host.close() }
        await host.settle { readerText(host) == "open stenoh now" }
        #expect(host.node(named: "Restore Original Cleanup") == nil)

        try await host.press("Clean Up Again")
        #expect(await host.settle { readerText(host) == "Open Steno now" },
                "reader: \(readerText(host) ?? "nothing")")
        #expect(await host.settle { host.node(named: "Restore Original Cleanup") != nil })
        #expect(host.node { $0.text.hasPrefix("Cleanup ran again") } != nil)

        try await host.press("Restore Original Cleanup")
        #expect(await host.settle { readerText(host) == "open stenoh now" },
                "reader: \(readerText(host) ?? "nothing")")
        #expect(await host.settle { host.node(named: "Restore Original Cleanup") == nil }, "the note stayed after Restore")
    }

    @Test("Fixing “the” from the list for future dictations asks about the common word, and confirming fixes it")
    func commonWordFromTheList() async throws {
        let first = F.entry("Send the plan to the team today.")
        let session = try await WindowDictation.make(entries: [first, F.entry("Please send the report to Kubernetes before lunch.", minutesAgo: 2)])
        defer { Task { await session.close() } }
        let feedback = GroveFeedback()
        feedback.announce = { _ in }
        let host = host(session.controller, feedback: feedback, selected: first.id)
        defer { host.close() }
        let isWordMenu: (NSPopUpButton) -> Bool = { $0.window != nil && !($0.window is TransitionWindow) }
        let field = { host.views(NSTextField.self).first { $0.placeholderString == "Correct spelling" && $0.window != nil } }
        await host.settle { readerText(host) != nil }
        host.window.makeKey()
        await host.keyPress(14, characters: "e", modifiers: .command)
        #expect(await host.settle { host.node(named: "Choose from a List…") != nil }, "⌘E did not show the hint: \(host.names())")
        try await host.press("Choose from a List…")
        #expect(await host.settle { host.views(NSPopUpButton.self).contains(where: isWordMenu) }, "no list of words")
        try await host.choose(menuItem: "the (1st)", in: isWordMenu)
        #expect(await host.settle { field()?.stringValue == "the" }, "the field says \(field()?.stringValue ?? "nothing")")
        // Typing first makes the field the one being edited, so it can be emptied.
        try await host.type("a", into: "Correct spelling")
        try await host.clearField()
        try await host.type("a", into: "Correct spelling")
        try await host.press("This and future dictations")
        await host.keyPress(36, characters: "\r")
        #expect(await host.settle { feedback.dialog != nil }, "no question about the common word")
        #expect(feedback.dialog?.title == "\u{201C}the\u{201D} is a common word. Fix it in this and future dictations?")
        feedback.resolveDialog(confirmed: true)
        #expect(await host.settle { readerText(host)?.contains("Send a plan") == true }, "after confirming, the reader says \(readerText(host) ?? "nothing")")
        #expect(session.controller.preferences.lexiconEntries.contains(LexiconEntry(term: "the", preferred: "a", scope: .global)))
    }
}

/// The search text a window passes down to History, observable by the test.
@MainActor
final class SearchBox: ObservableObject {
    @Published var text = ""
}

/// History with its search bound to a box, as the window binds it to its own state.
private struct SearchingHistory: View {
    @ObservedObject var box: SearchBox
    let selected: UUID?

    var body: some View {
        GroveHistoryView(searchQuery: $box.text, initialSelectedEntryID: selected)
    }
}

/// A hotkey service that never registers anything.
@MainActor
final class TransitionHotkey: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var onPasteLastShortcut: (() -> Void)?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16?
    func start() {}
    func stop() {}
}
