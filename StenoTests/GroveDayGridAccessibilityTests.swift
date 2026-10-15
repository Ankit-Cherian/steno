import AppKit
import Testing
@testable import Steno
@testable import StenoKit

/// An accessibility client in another process asks the calendar for its days, then asks each
/// day for its label in later calls. The days it was given must still exist when it asks.
@MainActor
@Suite("Grove day grid accessibility")
struct GroveDayGridAccessibilityTests {
    static func surface(selectedDate: Date?) -> GroveDayGridSurface {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 6))!
        let days = (0..<21).map { offset in
            UsageCalendarDay(date: calendar.date(byAdding: .day, value: offset, to: start)!, sessionCount: 1, wordCount: 10 * offset,
                             durationMS: 1_000, estimatedDurationSessionCount: 0, unavailableDurationSessionCount: 0, isTracked: true,
                             isActive: offset > 0, isInCurrentStreak: false)
        }
        let colors = GroveDayGridSurface.Colors(empty: .gray, levels: [.green, .green, .green, .green], uncounted: .lightGray, selected: .black)
        return GroveDayGridSurface(
            weeks: UsageCalendar(days: days, calendar: calendar).weeks, size: 12, gap: 3, maximumWords: 200, calendar: calendar,
            selectedDate: selectedDate, colors: colors, label: { _ in "" },
            spokenLabel: { "Day \(calendar.component(.day, from: $0.date))" }, onSelect: { _ in }
        )
    }

    static func days(of view: GroveDayGridView) -> [GroveDayCellElement] {
        (view.accessibilityChildren() ?? []).compactMap { $0 as? GroveDayCellElement }
    }

    @Test("The days stay the same objects between requests and outlive the request, until the calendar changes")
    func daysOutliveTheRequest() throws {
        let view = GroveDayGridView()
        view.update(Self.surface(selectedDate: nil))

        weak var firstDay: GroveDayCellElement?
        var labels: [String?] = []
        autoreleasepool {
            let days = Self.days(of: view)
            firstDay = days.first
            labels = days.map { $0.accessibilityLabel() }
        }
        #expect(labels.count == 21)
        #expect(labels.first == "Day 6")
        #expect(labels.last == "Day 26")
        #expect(firstDay != nil, "the day a client was given is gone before it can read it")

        let first = Self.days(of: view)
        let second = Self.days(of: view)
        #expect(first.count == 21)
        #expect(zip(first, second).allSatisfy { $0 === $1 }, "a second request made new days")
        #expect(first.first === firstDay)

        let chosen = try #require(first.last).accessibilityFrameInParentSpace()
        view.update(Self.surface(selectedDate: Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 26))))
        let afterChange = Self.days(of: view)
        #expect(afterChange.count == 21)
        #expect(!zip(first, afterChange).contains { $0 === $1 }, "the days were kept although the calendar changed")
        #expect(afterChange.last?.accessibilityFrameInParentSpace() == chosen)
        #expect(afterChange.last?.isAccessibilitySelected() == true, "the chosen day does not read as selected")
        #expect(afterChange.first?.isAccessibilitySelected() == false)
    }
}
