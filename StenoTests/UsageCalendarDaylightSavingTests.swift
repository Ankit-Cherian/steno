import Foundation
import Testing
@testable import Steno
import StenoKit

@MainActor
@Test(
    "Calendar weeks keep every day where daylight saving skips midnight",
    arguments: [
        ("America/Santiago", 2026, 9, 9),
        ("America/Havana", 2026, 3, 12),
        ("Africa/Cairo", 2026, 4, 28),
    ]
)
func calendarWeeksSurviveSkippedMidnight(zone: String, year: Int, month: Int, day: Int) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: zone))
    calendar.firstWeekday = 1
    let now = try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))

    let snapshot = UsageAnalyticsCalculator.snapshot(
        events: [], coverage: [], now: now, calendar: calendar, months: 6
    )
    let days = snapshot.dailyUsage.map { row in
        UsageCalendarDay(
            date: row.date,
            sessionCount: row.sessionCount,
            wordCount: row.wordCount,
            durationMS: row.durationMS,
            estimatedDurationSessionCount: row.estimatedDurationSessionCount,
            unavailableDurationSessionCount: row.unavailableDurationSessionCount,
            isTracked: row.isTracked,
            isActive: row.isActive,
            isInCurrentStreak: row.isInCurrentStreak
        )
    }
    let view = UsageCalendarView(
        days: days,
        theme: StenoDesign.theme(for: AppPreferences.default),
        calendar: calendar
    )

    let cells = view.weeks.flatMap(\.cells)
    let inRange = cells.filter(\.isInRange).map(\.date)
    #expect(inRange == days.map(\.date))
    #expect(Set(cells.map(\.date)).count == cells.count)
    #expect(cells.allSatisfy { calendar.startOfDay(for: $0.date) == $0.date })
    #expect(view.weeks.last?.cells.contains { calendar.isDate($0.date, inSameDayAs: now) } == true)
}
