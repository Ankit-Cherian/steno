import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

@Suite("Grove contrast")
struct GroveContrastTests {
    /// Every scheme and contrast setting.
    private static let themes: [GroveTheme] = [
        GroveTheme.resolve(scheme: .light, increaseContrast: false),
        .resolve(scheme: .light, increaseContrast: true),
        .resolve(scheme: .dark, increaseContrast: false),
        .resolve(scheme: .dark, increaseContrast: true)
    ]

    @Test("Text on the window ground and on raised surfaces reads at 4.5:1 or better", arguments: themes)
    func textOnSurfaces(theme: GroveTheme) {
        for surface in [theme.ground, theme.surface, theme.raised, theme.well, theme.selection] {
            #expect(theme.ink.contrastRatio(on: surface) >= 4.5, "ink on \(surface)")
            #expect(theme.ink2.contrastRatio(on: surface) >= 4.5, "ink2 on \(surface)")
        }
        for surface in [theme.ground, theme.raised, theme.surface] {
            #expect(theme.ink3.contrastRatio(on: surface) >= 4.5, "ink3 on \(surface)")
            #expect(theme.accent.contrastRatio(on: surface) >= 3, "accent on \(surface)")
        }
    }

    @Test("The meta line reads at 4.5:1 on a list row that is selected or pressed", arguments: themes)
    func metaTextOnRows(theme: GroveTheme) {
        for (name, fill) in [("selected", theme.rowSelection), ("pressed", theme.rowPressed)] {
            let row = fill.composited(over: theme.panel)
            #expect(theme.ink3.contrastRatio(on: row) >= 4.5, "ink3 on the \(name) row \(row)")
            #expect(theme.ink2.contrastRatio(on: row) >= 4.5, "ink2 on the \(name) row \(row)")
        }
    }

    @Test("Increase Contrast keeps the meta line at least as strong on a selected row", arguments: [ColorScheme.light, .dark])
    func metaTextOnRowsWithIncreaseContrast(scheme: ColorScheme) {
        func ratio(_ increased: Bool) -> Double {
            let theme = GroveTheme.resolve(scheme: scheme, increaseContrast: increased)
            return theme.ink3.contrastRatio(on: theme.rowSelection.composited(over: theme.panel))
        }
        #expect(ratio(true) >= ratio(false))
    }

    @Test("Cream and the soft tail read on every stop of forest glass", arguments: themes)
    func textOnForest(theme: GroveTheme) {
        for stop in [theme.forestTop, theme.forestMid, theme.forestBottom] {
            #expect(theme.cream.contrastRatio(on: stop) >= 7, "cream on \(stop)")
            #expect(theme.subtext.contrastRatio(on: stop) >= 4.5, "subtext on \(stop)")
            #expect(theme.mint.contrastRatio(on: stop) >= 3, "mint on \(stop)")
        }
        #expect(theme.onCream.contrastRatio(on: theme.cream) >= 7)
    }

    @Test("The menu bar panel's words read on every stop of its fill", arguments: themes)
    func textOnPanel(theme: GroveTheme) {
        for stop in [theme.panelTop, theme.panelMid, theme.panelBottom] {
            #expect(theme.cream.contrastRatio(on: stop) >= 7, "cream on \(stop)")
            #expect(theme.subtext.contrastRatio(on: stop) >= 4.5, "subtext on \(stop)")
            #expect(theme.mint.contrastRatio(on: stop) >= 3, "bars on \(stop)")
        }
        #expect(theme.onPanelCream.contrastRatio(on: theme.cream) >= 7)
    }

    @Test("The calendar's busiest day stands apart from the ground", arguments: themes)
    func calendarRamp(theme: GroveTheme) {
        #expect(GroveDayGrid.fillQuill(level: 4, theme: theme).contrastRatio(on: theme.ground) >= 3)
    }

    @Test("Buttons and chips keep their text readable", arguments: themes)
    func controls(theme: GroveTheme) {
        #expect(theme.onAccent.contrastRatio(on: theme.accent) >= 4.5)
        #expect(theme.caution.contrastRatio(on: theme.raised) >= 4.5)
        #expect(theme.error.contrastRatio(on: theme.raised) >= 3)
        // The selected navigation row: cream on the pill's two stops.
        for stop in [QuillColor(hex: 0x28563E), QuillColor(hex: 0x163B29)] {
            #expect(theme.cream.contrastRatio(on: stop) >= 7)
        }
    }
}

/// Reduce Transparency and larger text, which the standard renders do not show.
@Suite("Grove accessibility renders", .serialized)
@MainActor
struct GroveAccessibilityRenderingTests {
    typealias Variant = GroveRenderHarness.Variant
    typealias Harness = GroveRenderHarness

    @Test("Reduce Transparency draws solid forest", arguments: [Variant.light, .dark])
    func reduceTransparency(variant: Variant) async throws {
        let controller = Harness.sampleController(variant)
        controller.stageIsolatedPreviewLifecycle(.recordingHandsFree)
        controller.recordingStartedAt = Date().addingTimeInterval(-14)
        controller.stageIsolatedPreviewRecording(
            targetApp: "Mail", words: .init(stable: "Remind me to call the venue about the deposit ", tail: "before Friday"))
        try await Harness.write(ContentView(initialTab: .today), controller: controller, variant: variant,
                                reduceTransparency: true, name: "today-recording-solid-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("Larger text on Today", arguments: [Variant.light, .contrastDark])
    func largerToday(variant: Variant) async throws {
        let controller = Harness.sampleController(variant)
        try await Harness.write(ContentView(initialTab: .today), controller: controller, variant: variant,
                                textSize: .xxLarge, name: "today-large-text-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("Larger text on History", arguments: [Variant.light, .contrastDark])
    func largerHistory(variant: Variant) async throws {
        let controller = Harness.sampleController(variant)
        try await Harness.write(ContentView(initialTab: .history, initialState: .init(historyEntryID: WindowSampleData.latestID)),
                                controller: controller, variant: variant, textSize: .xxLarge,
                                name: "history-large-text-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("Larger text on Insights", arguments: [Variant.light])
    func largerInsights(variant: Variant) async throws {
        let controller = Harness.sampleController(variant)
        try await Harness.write(ContentView(initialTab: .insights), controller: controller, variant: variant,
                                textSize: .xxLarge, name: "insights-large-text-\(variant.rawValue)")
        await controller.teardownAndWait()
    }
}
