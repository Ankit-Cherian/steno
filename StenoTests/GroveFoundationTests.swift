import Foundation
import StenoKit
import SwiftUI
import Testing
@testable import Steno

@Suite("Grove rules")
struct GroveRulesTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func entry(_ hour: Int, _ minute: Int, day: Int = 5, status: InsertionStatus = .inserted) -> TranscriptEntry {
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        return TranscriptEntry(createdAt: date, appBundleID: "com.example", rawText: "text", cleanText: "text", audioURL: nil, insertionStatus: status)
    }

    @Test("Around then keeps the half hour before, oldest first")
    func windowAndOrder() {
        let selected = entry(10, 24)
        let result = GroveRules.aroundThen(for: selected, in: [entry(10, 10), entry(9, 58), entry(9, 31), selected, entry(10, 40)], calendar: calendar)
        #expect(result.map(\.createdAt) == [entry(9, 58).createdAt, entry(10, 10).createdAt])
    }

    @Test("Around then stays on the same day and holds at most three")
    func dayAndLimit() {
        let selected = entry(0, 10)
        let yesterday = entry(23, 50, day: 4)
        #expect(GroveRules.aroundThen(for: selected, in: [yesterday, selected], calendar: calendar).isEmpty)
        let busy = entry(11, 0)
        let others = [entry(10, 35), entry(10, 40), entry(10, 45), entry(10, 50)]
        let result = GroveRules.aroundThen(for: busy, in: others + [busy], calendar: calendar)
        #expect(result.map(\.createdAt) == [entry(10, 40).createdAt, entry(10, 45).createdAt, entry(10, 50).createdAt])
    }

    @Test("Chips say why a dictation was copied")
    func chips() {
        #expect(GroveRules.chips(for: entry(9, 0)).isEmpty)
        #expect(GroveRules.chips(for: entry(9, 0, status: .failed)).map(\.text) == ["Not inserted · Saved in History"])
        #expect(GroveRules.chips(for: entry(9, 0, status: .copiedOnly)).map(\.text) == ["Copied"])
        #expect(GroveRules.copyReasonText("appChanged") == "App changed")
        #expect(GroveRules.copyReasonText("secureField") == "Password field")
    }
}

@Suite("Grove non-text contrast")
struct GroveNonTextContrastTests {
    @Test("Focus rings and the Increase Contrast edges reach 3:1 against what they sit on",
          arguments: [ColorScheme.light, .dark])
    func rings(scheme: ColorScheme) {
        let theme = GroveTheme.resolve(scheme: scheme, increaseContrast: false)
        // A ring on forest glass is mint; elsewhere it is the accent on the page.
        for glass in [theme.forestTop, theme.forestMid, theme.forestBottom] {
            #expect(theme.mint.contrastRatio(on: glass) >= 3, "mint ring on forest")
        }
        #expect(theme.accent.contrastRatio(on: theme.ground) >= 3, "accent ring on the page")
        let contrast = GroveTheme.resolve(scheme: scheme, increaseContrast: true)
        let panel = QuillColor(hex: scheme == .dark ? 0x1D1F1E : 0xFFFFFF)
        #expect(contrast.ring.contrastRatio(on: contrast.ground) >= 3, "outline of a raised card")
        #expect(contrast.panelEdge.contrastRatio(on: panel) >= 3, "panel edge")
    }
}
