import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Insights' calendar chosen by click, by the keys and by VoiceOver, with the line under it
/// following each choice.
@Suite("Insights transitions", .serialized)
@MainActor
struct InsightsTransitionTests {
    typealias F = TransitionFixtures

    static func host(_ controller: DictationController) -> TransitionHost {
        TransitionHost(controller: controller) {
            GroveRenderHarness.window(.insights, controller: controller) { GroveInsightsView() }
        }
    }

    /// The day cells VoiceOver reads, in grid order.
    static func cells(_ host: TransitionHost) -> [GroveDayCellElement] {
        (host.views(GroveDayGridView.self).first?.accessibilityChildren() ?? []).compactMap { $0 as? GroveDayCellElement }
    }

    /// The line under the calendar for `date`, as drawn, or nil when no day is chosen.
    static func chosenLine(_ host: TransitionHost, for date: Date) -> TransitionHost.Node? {
        let title = date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        return host.node { $0.text.hasPrefix(title + "  ") }
    }

    /// The date a cell's label names: "Saturday, May 30, 2026. 363 words …".
    static func date(of cell: GroveDayCellElement) -> Date? {
        guard let label = cell.accessibilityLabel(), let head = label.split(separator: ".").first else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "EEEE, MMMM d, yyyy"
        return parser.date(from: String(head))
    }

    @Test("The calendar fills the panel beside its facts at the default and a large window")
    func calendarFillsThePanel() async throws {
        for size in [GroveRenderHarness.windowSize, CGSize(width: 1440, height: 1000)] {
            let host = TransitionHost(size: size, controller: F.sampleController()) {
                GroveRenderHarness.window(.insights, controller: F.sampleController()) { GroveInsightsView() }
            }
            defer { host.close() }
            await host.settle { !Self.cells(host).isEmpty }
            let grid = try #require(host.views(GroveDayGridView.self).first)
            // Cells capped at 18 pt drew about 500 pt of weeks and left the rest of the panel empty.
            #expect(grid.frame.width >= 600, "the weeks fill \(Int(grid.frame.width)) pt of a \(Int(size.width)) pt window")
        }
    }

    /// The width a test gives the window's content, changed while the view stays on screen.
    final class Width: ObservableObject {
        @Published var value: CGFloat
        init(_ value: CGFloat) { self.value = value }
    }

    private struct Sized<Content: View>: View {
        @ObservedObject var width: Width
        let content: Content
        var body: some View { content.frame(width: width.value).frame(maxWidth: .infinity, alignment: .leading) }
    }

    @Test("Narrowing the window shrinks the calendar's cells: the weeks and the busiest day stay inside the panel")
    func calendarShrinksWithTheWindow() async throws {
        let controller = F.sampleController()
        // An hour of words every day, so the page is long enough to scroll.
        controller.usageAnalyticsSnapshot = WindowSampleData.usageSnapshot(dailyWords: Dictionary(uniqueKeysWithValues: (0..<180).map { ($0, 55_555) }))
        let width = Width(GroveRenderHarness.windowSize.width)
        let host = TransitionHost(size: GroveRenderHarness.windowSize, controller: controller) {
            Sized(width: width, content: GroveRenderHarness.window(.insights, controller: controller) { GroveInsightsView() })
        }
        defer { host.close() }
        #expect(await host.settle { !Self.cells(host).isEmpty })
        for narrower in [MainWindowMetrics.minWidth, 900] {
            width.value = narrower
            await host.settle(timeout: .milliseconds(500)) { false }
            let right = host.window.frame.minX + narrower
            let page = try #require(host.views(NSScrollView.self).first { $0.documentView != nil && $0.window === host.window })
            #expect(page.frame.width <= narrower + 0.5, "at \(Int(narrower)) pt the page is \(page.frame.width) pt wide")
            let fact = try #require(host.node { $0.text.hasPrefix("Busiest day") || $0.name.hasPrefix("Busiest day") }, "no Busiest day")
            #expect(fact.screenFrame.maxX <= right - GroveMetrics.columnMargin + 0.5,
                    "at \(Int(narrower)) pt Busiest day ends at \(fact.screenFrame.maxX - host.window.frame.minX)")
            let grid = try #require(host.views(GroveDayGridView.self).first)
            #expect(grid.convert(grid.bounds, to: nil).minX >= GroveMetrics.columnMargin, "the weeks start off the left of the panel")
        }
    }

    @Test("Every month is named above the calendar, also when the first week holds the 1st of the next month")
    func everyMonthIsNamed() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        // The labels are written in this Mac's time zone, as the calendar's days are.
        calendar.timeZone = .current
        func day(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: day))! }
        // Wednesday, April 29: the first week runs to Saturday, May 2, so it holds May 1.
        for start in [day(4, 29), day(4, 26), day(4, 12)] {
            let days = (0..<70).map { offset in
                UsageCalendarDay(date: calendar.date(byAdding: .day, value: offset, to: start)!, sessionCount: 0, wordCount: 0, durationMS: 0,
                                 estimatedDurationSessionCount: 0, unavailableDurationSessionCount: 0, isTracked: true,
                                 isActive: false, isInCurrentStreak: false)
            }
            let weeks = UsageCalendar(days: days, calendar: calendar).weeks
            let names = weeks.enumerated().compactMap { GroveDayGrid.monthLabel(for: $1, at: $0, calendar: calendar) }
            // Every month whose 1st is on the calendar is named.
            let firsts = days.filter { calendar.component(.day, from: $0.date) == 1 }.map { $0.date.formatted(.dateTime.month(.abbreviated)) }
            for name in firsts {
                #expect(names.contains(name), "starting \(start): \(name) is never named; labels \(names)")
            }
            #expect(names.count == Set(names).count, "a month is named twice: \(names)")
        }
    }

    @Test("A click picks a day: the ring moves to it and the line under the calendar describes it")
    func clickPicksADay() async throws {
        let host = Self.host(F.sampleController())
        defer { host.close() }
        await host.settle { !Self.cells(host).isEmpty }
        let grid = try #require(host.views(GroveDayGridView.self).first)
        let active = Self.cells(host).filter { $0.accessibilityLabel()?.contains(" words") == true }
        try #require(active.count >= 2)
        #expect(!Self.cells(host).contains { $0.isAccessibilitySelected() }, "a day is ringed before any is chosen")

        for cell in [active[0], active[active.count - 1]] {
            let date = try #require(Self.date(of: cell))
            let frame = cell.accessibilityFrameInParentSpace()
            await host.click(grid, at: CGPoint(x: frame.midX, y: frame.midY))
            #expect(await host.settle { Self.chosenLine(host, for: date) != nil }, "the line does not describe \(date)")
            let words = try #require(cell.accessibilityLabel()?.split(separator: ".").dropFirst().joined(separator: ".")
                .split(separator: ",").first?.trimmingCharacters(in: .whitespaces))
            #expect(Self.chosenLine(host, for: date)?.text.contains(words) == true, "the line does not say \(words)")
            let selected = Self.cells(host).filter { $0.isAccessibilitySelected() }
            #expect(selected.count == 1, "\(selected.count) days read as selected")
            #expect(selected.first.flatMap(Self.date(of:)) == date)
        }
    }

    @Test("The arrow keys move the chosen day a day or a week, and the line follows")
    func keysMoveTheDay() async throws {
        let host = Self.host(F.sampleController())
        defer { host.close() }
        await host.settle { !Self.cells(host).isEmpty }
        let grid = try #require(host.views(GroveDayGridView.self).first)
        let cells = Self.cells(host)
        // A day with room for a week either way.
        let start = try #require(cells.compactMap(Self.date(of:)).sorted()[safe: 30])
        let cell = try #require(cells.first { Self.date(of: $0) == start })
        let frame = cell.accessibilityFrameInParentSpace()
        await host.click(grid, at: CGPoint(x: frame.midX, y: frame.midY))
        #expect(await host.settle { Self.chosenLine(host, for: start) != nil })
        #expect(host.window.firstResponder is GroveKeyView, "the calendar did not take the keyboard")

        let calendar = Calendar.current
        let steps: [(UInt16, Int)] = [(125, 1), (124, 7), (126, -1), (123, -7)]
        var expected = start
        for (key, days) in steps {
            expected = try #require(calendar.date(byAdding: .day, value: days, to: expected))
            await host.key(key)
            #expect(await host.settle { Self.chosenLine(host, for: expected) != nil },
                    "key \(key) did not move to \(expected)")
            #expect(Self.cells(host).filter { $0.isAccessibilitySelected() }.compactMap(Self.date(of:))
                .allSatisfy { calendar.isDate($0, inSameDayAs: expected) })
        }
    }

    @Test("VoiceOver's press on a day chooses it like a click")
    func voiceOverPressChoosesADay() async throws {
        let host = Self.host(F.sampleController())
        defer { host.close() }
        await host.settle { !Self.cells(host).isEmpty }
        let cell = try #require(Self.cells(host).last { $0.accessibilityLabel()?.contains(" words") == true })
        let date = try #require(Self.date(of: cell))
        #expect(cell.accessibilityPerformPress())
        #expect(await host.settle { Self.chosenLine(host, for: date) != nil })
        #expect(Self.cells(host).first { $0.isAccessibilitySelected() }.flatMap(Self.date(of:)) == date)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
