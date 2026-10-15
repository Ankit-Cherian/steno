import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// The window's sections switched back and forth through the section control: each one comes
/// back where it was left, and nothing from the section before stays on screen.
@Suite("Window section transitions", .serialized)
@MainActor
struct ShellTransitionTests {
    typealias F = TransitionFixtures

    private func isOnToday(_ host: TransitionHost) -> Bool { host.node(identifier: "today.start") != nil }
    private func isOnHistory(_ host: TransitionHost) -> Bool { host.node(identifier: "history.more") != nil }
    private func isOnInsights(_ host: TransitionHost) -> Bool { host.node(named: "The last six months") != nil }

    @Test("Today, History and Insights each show only their own content after every switch")
    func nothingStaleAfterASwitch() async throws {
        let controller = F.sampleController()
        let host = TransitionHost(controller: controller) { ContentView() }
        defer { host.close() }
        await host.settle { isOnToday(host) }

        for (segment, check) in [("History", isOnHistory), ("Insights", isOnInsights), ("Today", isOnToday),
                                 ("Insights", isOnInsights), ("History", isOnHistory), ("Today", isOnToday)] {
            try await host.selectSegment(segment)
            #expect(await host.settle { check(host) }, "\(segment) did not show: \(host.names().prefix(12))")
            let shown = [isOnToday(host), isOnHistory(host), isOnInsights(host)].filter { $0 }.count
            #expect(shown == 1, "\(shown) sections on screen after switching to \(segment)")
            if segment == "Insights" { #expect(host.transcriptViews().isEmpty, "dictation text stayed on Insights") }
            if segment == "History" { #expect(host.views(GroveDayGridView.self).isEmpty, "the calendar stayed on History") }
        }
    }

    @Test("History keeps its dictation, filter and search, and Insights its day, across switches")
    func sectionsKeepTheirPlace() async throws {
        let controller = F.sampleController()
        let host = TransitionHost(controller: controller) { ContentView() }
        defer { host.close() }
        await host.settle { isOnToday(host) }

        try await host.selectSegment("History")
        #expect(await host.settle { isOnHistory(host) })
        // The third dictation, not the first that History opens on.
        try await host.pressRow(containing: "The parties agree", in: "Dictations")
        #expect(await host.settle { host.transcriptViews().first?.textStorage?.string.hasPrefix("The parties agree") == true })
        try await host.choose(menuItem: HistoryFilter.inserted.menuTitle)
        #expect(await host.settle { host.node(identifier: "history.filter")?.value == HistoryFilter.inserted.menuTitle })
        let reader = host.transcriptViews().first?.textStorage?.string
        #expect(reader?.hasPrefix("The parties agree") == true, "the filter moved the selection")

        try await host.selectSegment("Insights")
        #expect(await host.settle { isOnInsights(host) && !InsightsTransitionTests.cells(host).isEmpty })
        let cell = try #require(InsightsTransitionTests.cells(host).first { $0.accessibilityLabel()?.contains(" words") == true })
        let day = try #require(InsightsTransitionTests.date(of: cell))
        #expect(cell.accessibilityPerformPress())
        #expect(await host.settle { InsightsTransitionTests.chosenLine(host, for: day) != nil })

        try await host.selectSegment("Today")
        #expect(await host.settle { isOnToday(host) })

        try await host.selectSegment("History")
        #expect(await host.settle { isOnHistory(host) && host.transcriptViews().first != nil })
        #expect(host.transcriptViews().first?.textStorage?.string == reader, "History came back on another dictation")
        #expect(host.node(identifier: "history.filter")?.value == HistoryFilter.inserted.menuTitle, "History lost its filter")

        try await host.selectSegment("Insights")
        #expect(await host.settle { InsightsTransitionTests.chosenLine(host, for: day) != nil }, "Insights lost the chosen day")
        #expect(InsightsTransitionTests.cells(host).filter { $0.isAccessibilitySelected() }.count == 1)
    }
}
