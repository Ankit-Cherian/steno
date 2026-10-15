import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Worst-case content driven through live windows rather than drawn once: right-to-left words,
/// an unbreakable link, a long email opened in full, 1,000 dictations searched and walked by
/// key, a long word correction, and the newest lines at the smallest windows.
@Suite("Worst-case content in live windows", .serialized)
@MainActor
struct WorstCaseTransitionTests {
    typealias F = TransitionFixtures

    private static var entries: [TranscriptEntry] {
        WindowSampleData.worstCaseEntries() + WindowSampleData.thousandEntries()
    }

    /// Named elements that stick out of the window on the left or right.
    private func overflowing(_ host: TransitionHost) -> [String] {
        let window = host.window.frame.insetBy(dx: -1, dy: -1)
        return host.nodes().filter { node in
            let frame = node.screenFrame
            return !node.name.isEmpty && frame.width > 0 && (frame.minX < window.minX || frame.maxX > window.maxX)
        }.map { String($0.name.prefix(40)) }
    }

    private func history(_ controller: DictationController, query: SearchBox, size: CGSize = GroveRenderHarness.windowSize) -> TransitionHost {
        TransitionHost(size: size, controller: controller) {
            GroveRenderHarness.window(.history, controller: controller) { WorstSearchHistory(box: query) }
        }
    }

    @Test("With 1,000 dictations, a search finds a right-to-left one, the reader sets it from the right, and it fits the window")
    func searchFindsRightToLeft() async throws {
        let query = SearchBox()
        let host = history(F.sampleController(Self.entries), query: query, size: GroveRenderHarness.minimumSize)
        defer { host.close() }
        await host.settle { host.transcriptViews().first != nil }
        try await host.type("החוזה", into: "Search dictations")
        #expect(await host.settle { host.transcriptViews().first?.textStorage?.string.contains("החוזה") == true },
                "the reader shows \(host.transcriptViews().first?.textStorage?.string.prefix(30) ?? "nothing")")
        let view = try #require(host.transcriptViews().first)
        let style = view.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.alignment == .right || style?.baseWritingDirection == .rightToLeft,
                "right-to-left words are set from the left (alignment \(String(describing: style?.alignment.rawValue)))")
        #expect(DrawnText(view).showsWholeText)
        #expect(overflowing(host).isEmpty, "\(overflowing(host))")
    }

    @Test("An unbreakable link wraps inside the reader at the smallest window, and Show all opens the long email in full")
    func unbreakableAndLongEmail() async throws {
        let entries = WindowSampleData.worstCaseEntries()
        let link = try #require(entries.first { $0.cleanText == WindowSampleData.unbreakableToken })
        let controller = F.sampleController(entries)
        let host = TransitionHost(size: GroveRenderHarness.minimumSize, controller: controller) {
            GroveRenderHarness.window(.history, controller: controller) {
                GroveHistoryView(initialSelectedEntryID: link.id)
            }
        }
        defer { host.close() }
        await host.settle { host.transcriptViews().first?.textStorage?.string.hasPrefix("https://") == true }
        let drawn = DrawnText(try #require(host.transcriptViews().first))
        #expect(drawn.showsWholeText, "the link was cut: \(drawn)")
        #expect(drawn.lines > 1, "the link did not wrap")
        #expect(overflowing(host).isEmpty, "\(overflowing(host))")

        try await host.pressRow(containing: "Hi Dana", in: "Dictations")
        try await host.press(prefix: "Show All ")
        #expect(await host.settle { host.transcriptViews().first.map { DrawnText($0).showsWholeText } ?? false },
                "the long email is still cut after Show all")
    }

    @Test("The arrow keys walk 1,000 dictations without losing the selection, and the reader keeps up")
    func walkAThousand() async throws {
        let entries = Self.entries
        let host = history(F.sampleController(entries), query: SearchBox())
        defer { host.close() }
        await host.settle { host.transcriptViews().first != nil }
        // A row is named by its preview, where runs of spaces and line breaks read as one space.
        try await host.pressRow(containing: String(GrovePreviewText.make(entries[0].displayText).prefix(12)), in: "Dictations")
        for _ in 0..<40 { await host.key(125) }
        let expected = GroveFlowText.displayText(entries[40].cleanText)
        #expect(await host.settle { host.transcriptViews().first?.textStorage?.string == expected || entries[40].cleanText.isEmpty },
                "after 40 steps the reader shows \(host.transcriptViews().first?.textStorage?.string.prefix(30) ?? "nothing")")
        let selected = host.nodes(under: host.node { $0.name == "Dictations" }).filter(\.isSelected)
        #expect(selected.count == 1, "\(selected.count) rows read as selected")
        let window = host.window.frame
        #expect(selected.first.map { window.intersects($0.screenFrame) } == true, "the selected row scrolled out of view")
    }

    @Test("A long word correction stays inside the Settings window at its smallest, with Remove in reach")
    func longCorrection() async throws {
        let controller = F.sampleController()
        let session = SettingsSession(previewDraft: SettingsDraftState(saved: controller.preferences), section: .corrections)
        let host = TransitionHost(size: CGSize(width: 760, height: 520), controller: controller) { SettingsView(session: session) }
        defer { host.close() }
        await host.settle { host.node(named: "Add") != nil }
        let term = "northwindindustriesholdingsdesktopclientquarterlyreview"
        try await host.type(term, into: "Misheard word")
        try await host.type("Northwind Industries Holdings Desktop Client Quarterly Review", into: "Correct word")
        try await host.press("Add")
        #expect(await host.settle { host.node(named: "Remove \(term)") != nil })
        let window = host.window.frame
        let remove = try #require(host.node(named: "Remove \(term)"))
        #expect(window.contains(remove.screenFrame), "Remove is at \(remove.screenFrame), outside \(window)")
        #expect(overflowing(host).isEmpty, "\(overflowing(host))")
    }

    @Test("Insights at the smallest window keeps the calendar's lines inside it, before and after a day is chosen")
    func insightsMinimum() async throws {
        let controller = F.sampleController()
        controller.usageAnalyticsSnapshot = WindowSampleData.usageSnapshot(dailyWords: [0: 1_234_567, 1: 987_654, 30: 12])
        let host = TransitionHost(size: GroveRenderHarness.minimumSize, controller: controller) {
            GroveRenderHarness.window(.insights, controller: controller) { GroveInsightsView() }
        }
        defer { host.close() }
        await host.settle { !InsightsTransitionTests.cells(host).isEmpty }
        #expect(overflowing(host).isEmpty, "\(overflowing(host))")
        let cell = try #require(InsightsTransitionTests.cells(host).last { $0.accessibilityLabel()?.contains(" words") == true })
        #expect(cell.accessibilityPerformPress())
        await host.settle()
        #expect(overflowing(host).isEmpty, "after choosing a day: \(overflowing(host))")
    }
}

private struct WorstSearchHistory: View {
    @ObservedObject var box: SearchBox

    var body: some View {
        GroveHistoryView(searchQuery: $box.text)
    }
}
