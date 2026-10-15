import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Saved dictations whose text is unusual, on Today's latest card and in History's reader: none
/// at all, as an old no-speech entry, and words padded with blank lines and spaces.
@Suite("Dictation text transitions", .serialized)
@MainActor
struct EntryTextTransitionTests {
    typealias F = TransitionFixtures

    private func today(_ controller: DictationController) -> TransitionHost {
        TransitionHost(controller: controller) {
            GroveRenderHarness.window(.today, controller: controller) { GroveTodayView() }
        }
    }

    private func history(_ controller: DictationController, selected: UUID) -> TransitionHost {
        TransitionHost(controller: controller) {
            GroveRenderHarness.window(.history, controller: controller) { GroveHistoryView(initialSelectedEntryID: selected) }
        }
    }

    private func says(_ host: TransitionHost, _ prefix: String) -> Bool {
        host.node { $0.text.hasPrefix(prefix) } != nil
    }

    /// Buttons outside History's list, and anywhere on Today, whose name starts with `prefix`.
    private func actions(_ host: TransitionHost, _ prefix: String) -> [TransitionHost.Node] {
        let list = host.node { $0.name == "Dictations" }
        let listed = Set((list.map { host.nodes(under: $0) } ?? []).map { ObjectIdentifier($0.object) })
        return host.nodes().filter { $0.role == "AXButton" && $0.name.hasPrefix(prefix) && !listed.contains(ObjectIdentifier($0.object)) }
    }

    // MARK: No words

    @Test("History's reader offers no Copy and no Fix a Word for a dictation with no words, and both for one with words")
    func historyNoWords() async throws {
        let empty = F.entry("", status: .noSpeech, raw: "")
        let spoken = F.entry("Send the slides to Dana.", minutesAgo: 3)
        let controller = F.sampleController([empty, spoken])
        let host = history(controller, selected: empty.id)
        defer { host.close() }
        #expect(await host.settle { says(host, "No speech detected") }, "\(host.names().prefix(12))")
        #expect(actions(host, "Copy").isEmpty, "an empty dictation offers Copy")
        #expect(actions(host, "Fix a Word").isEmpty, "an empty dictation offers Fix a Word")
        #expect(!actions(host, "Delete").isEmpty, "Delete went too")

        try await host.pressRow(containing: "Send the slides", in: "Dictations")
        #expect(await host.settle { host.transcriptViews().first?.textStorage?.string == GroveFlowText.displayText(spoken.cleanText) })
        #expect(!actions(host, "Copy").isEmpty)
        #expect(!actions(host, "Fix a Word").isEmpty)
    }

    @Test("Today's latest card offers no Copy and no Fix a Word when the latest dictation has no words")
    func todayNoWords() async throws {
        let empty = F.entry("", status: .noSpeech, raw: "")
        let host = today(F.sampleController([empty, F.entry("Send the slides to Dana.", minutesAgo: 3)]))
        defer { host.close() }
        // The card stands for the empty dictation: its actions are there and no words are drawn.
        #expect(await host.settle { !actions(host, "How It Was Written").isEmpty }, "\(host.names().prefix(12))")
        #expect(host.transcriptViews().isEmpty, "the card shows another dictation's words")
        #expect(actions(host, "Copy").isEmpty, "an empty dictation offers Copy")
        #expect(actions(host, "Fix a Word").isEmpty, "an empty dictation offers Fix a Word")

        let words = today(F.sampleController([F.entry("Send the slides to Dana.")]))
        defer { words.close() }
        #expect(await words.settle { words.transcriptViews().first != nil })
        #expect(!actions(words, "Copy").isEmpty)
        #expect(!actions(words, "Fix a Word").isEmpty)
    }

    // MARK: Padded words

    @Test("Blank lines and spaces around a dictation's words are not drawn on Today's card or in History's reader, and its ranges still line up")
    func paddedWordsDrawTrimmed() async throws {
        let padded = WindowSampleData.padded
        let trimmed = padded.trimmingCharacters(in: .whitespacesAndNewlines)
        for page in ["Today", "History"] {
            var drawn: [(height: CGFloat, firstWordX: CGFloat)] = []
            for text in [padded, trimmed] {
                let entry = F.entry(text)
                let controller = F.sampleController([entry])
                let host = page == "Today" ? today(controller) : history(controller, selected: entry.id)
                defer { host.close() }
                #expect(await host.settle { host.transcriptViews().first != nil }, "\(page) drew no words")
                let view = try #require(host.transcriptViews().first)
                let shown = (view.textStorage?.string ?? "") as NSString
                let stored = text as NSString
                // Fix a Word and search marks use ranges of the stored text.
                #expect(shown.length == stored.length, "\(page) drew \(shown.length) units for \(stored.length)")
                #expect(shown.range(of: "land").location == stored.range(of: "land").location)
                let call = view.firstRect(forCharacterRange: stored.range(of: "Call"), actualRange: nil)
                drawn.append((view.frame.height, call.minX))
            }
            #expect(drawn[0].height == drawn[1].height, "\(page): padded words take \(drawn[0].height) pt, trimmed \(drawn[1].height) pt")
            #expect(abs(drawn[0].firstWordX - drawn[1].firstWordX) < 0.5,
                    "\(page): padded words start at \(drawn[0].firstWordX), trimmed at \(drawn[1].firstWordX)")
        }
    }
}
