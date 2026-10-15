import AppKit
import SwiftUI
import Testing
@testable import Steno

/// The colour scheme switched while views are on screen. A view that was switched must draw
/// exactly as one created in the new scheme: no colour, mark or stage may stay from before.
@Suite("Live appearance switches", .serialized)
@MainActor
struct LiveSwitchTransitionTests {
    typealias F = TransitionFixtures

    enum Surface: String, CaseIterable, CustomTestStringConvertible {
        case today, history, insights
        var testDescription: String { rawValue }
    }

    private func host(_ surface: Surface, knobs: TransitionKnobs) -> TransitionHost {
        let controller = F.sampleController()
        return TransitionHost(controller: controller, knobs: knobs) {
            switch surface {
            case .today: GroveRenderHarness.window(.today, controller: controller) { GroveTodayView() }
            case .history: GroveRenderHarness.window(.history, controller: controller) {
                // A search, so the matches are marked in the accent.
                GroveHistoryView(searchQuery: .constant("agenda"), initialSelectedEntryID: WindowSampleData.latestID)
            }
            case .insights: GroveRenderHarness.window(.insights, controller: controller) { GroveInsightsView() }
            }
        }
    }

    /// What `surface` draws when it is created in `scheme`.
    private func fresh(_ surface: Surface, scheme: ColorScheme) async throws -> NSBitmapImageRep {
        let knobs = TransitionKnobs()
        knobs.scheme = scheme
        let host = host(surface, knobs: knobs)
        defer { host.close() }
        await host.settle()
        await host.pump(.milliseconds(60))
        return try #require(host.bitmap())
    }

    @Test("Light to dark while on screen draws what a fresh dark view draws", arguments: Surface.allCases)
    func schemeSwitch(surface: Surface) async throws {
        let dark = try await fresh(surface, scheme: .dark)
        let knobs = TransitionKnobs()
        let host = host(surface, knobs: knobs)
        defer { host.close() }
        await host.settle()
        knobs.scheme = .dark
        await host.settle()
        await host.pump(.milliseconds(60))
        let live = try #require(host.bitmap())
        let stale = TransitionHost.difference(live, dark)
        #expect(stale < 0.002, "\(surface) after the switch differs from a fresh dark view in \(String(format: "%.2f", stale * 100))% of pixels")
    }
}
