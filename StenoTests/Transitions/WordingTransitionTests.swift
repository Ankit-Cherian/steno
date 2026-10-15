import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Words that must agree across the app: where a dictation that was not inserted went, what a
/// confirm button applies to, why History's reader is empty, and menu items in title case.
@Suite("Wording across screens", .serialized)
@MainActor
struct WordingTransitionTests {
    typealias F = TransitionFixtures

    @Test("A dictation that was not inserted is Saved in History on Today's note and in its chip")
    func savedInHistory() {
        let failed = F.entry(WindowSampleData.booking, status: .failed)
        guard case .problem(let note) = GroveTodayFlow.resolve(failed, appName: "Mail") else {
            Issue.record("a failed dictation did not become a note")
            return
        }
        #expect(note.message.hasPrefix("Saved in History."), "Today says “\(note.message)”")
        #expect(GroveRules.chips(for: failed).map(\.text).contains("Not inserted · Saved in History"))
    }

    private func history(_ controller: DictationController, filter: HistoryFilter = .all) -> TransitionHost {
        TransitionHost(controller: controller) {
            GroveRenderHarness.window(.history, controller: controller) { SearchableGroveHistory(filter: filter) }
        }
    }

    @Test("A search that matches nothing says so in the reader, instead of asking to select a dictation")
    func emptySearchReader() async throws {
        let host = history(F.sampleController(WindowSampleData.entries()))
        defer { host.close() }
        await host.settle { host.node(named: "Search dictations") != nil }
        try await host.type("zqxj", into: "Search dictations")
        #expect(await host.settle { host.node { $0.text.hasPrefix("No dictations match") && !$0.text.contains("“") } != nil },
                "the reader does not say nothing matches: \(host.names())")
        #expect(host.node { $0.text.hasPrefix("Select a dictation") } == nil, "the reader still asks to select a dictation")
    }

    @Test("A filter with nothing in it says so in the reader")
    func emptyFilterReader() async throws {
        let host = history(F.sampleController([F.entry(WindowSampleData.booking)]), filter: .notInserted)
        defer { host.close() }
        #expect(await host.settle { host.node { $0.text.hasPrefix("No dictations to show") } != nil },
                "the reader does not say the filter is empty: \(host.names())")
        #expect(host.node { $0.text.hasPrefix("Select a dictation") } == nil)
    }

    @Test("The menu bar card names a dictation with no words instead of drawing nothing")
    func emptyMenuCard() {
        #expect(GroveMenuView.cardText(for: F.entry("", status: .noSpeech, raw: "")) == ("No speech detected", false))
        #expect(GroveMenuView.cardText(for: F.entry("", raw: "")) == ("No text", false))
        #expect(GroveMenuView.cardText(for: F.entry("Send it.")) == ("Send it.", true))
    }

    @Test("Fixing a common word asks with a button that names this and future dictations, as the question does")
    func commonWordConfirm() {
        let title = FixableTranscriptEntry.commonWordTitle("the")
        #expect(title.hasSuffix("Fix it in this and future dictations?"))
        #expect(FixableTranscriptEntry.commonWordConfirmTitle == "Fix This and Future Dictations")
    }

    @Test("Word Corrections names All Apps in title case, and its confirm button names where the fix applies")
    func allApps() async throws {
        let controller = F.sampleController()
        let session = SettingsSession(previewDraft: SettingsDraftState(saved: controller.preferences), section: .corrections)
        let host = TransitionHost(size: CGSize(width: 860, height: 1_000), controller: controller) { SettingsView(session: session) }
        defer { host.close() }
        #expect(await host.settle { host.node(named: "Apps") != nil }, "no Apps menu: \(host.names().prefix(30))")
        #expect(host.node(named: "Apps")?.value == "All Apps")
        #expect(LexiconSettingsSection.commonWordConfirmTitle(.global) == "Fix in Every Dictation")
        #expect(AppIdentity.scopeTitle(.global) == "All Apps")
    }
}
