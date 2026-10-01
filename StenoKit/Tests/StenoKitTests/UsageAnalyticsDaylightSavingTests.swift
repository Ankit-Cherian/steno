import Foundation
import Testing
@testable import StenoKit

/// Zones whose daylight-saving change skips or repeats local midnight. Each
/// case dictates on consecutive days across the change and looks a few days
/// later, while the change is inside the calendar window.
@Suite("Usage calendar across daylight-saving changes at midnight")
struct UsageAnalyticsDaylightSavingTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var zone: String
        /// The local day whose midnight the clock change skips, when it does.
        var skippedMidnight: (year: Int, month: Int, day: Int)?
        var firstActiveDay: (year: Int, month: Int, day: Int)
        var today: (year: Int, month: Int, day: Int)

        var testDescription: String { "\(zone) \(today.month)/\(today.day)" }
    }

    static let cases: [Case] = [
        Case(zone: "America/Havana", skippedMidnight: (2026, 3, 8), firstActiveDay: (2026, 3, 5), today: (2026, 3, 12)),
        Case(zone: "America/Santiago", skippedMidnight: (2026, 9, 6), firstActiveDay: (2026, 9, 3), today: (2026, 9, 9)),
        Case(zone: "Africa/Cairo", skippedMidnight: (2026, 4, 24), firstActiveDay: (2026, 4, 21), today: (2026, 4, 28)),
        // Months after the change, the window still contains the skipped midnight.
        Case(zone: "America/Havana", skippedMidnight: (2026, 3, 8), firstActiveDay: (2026, 6, 1), today: (2026, 6, 5)),
        // Clocks go back at midnight, repeating the hour before it.
        Case(zone: "America/Santiago", skippedMidnight: nil, firstActiveDay: (2026, 4, 2), today: (2026, 4, 8)),
        Case(zone: "America/Havana", skippedMidnight: nil, firstActiveDay: (2026, 10, 29), today: (2026, 11, 4)),
    ]

    @Test("Rows are whole local days, today is the last row, and the streak is unbroken", arguments: cases)
    func calendarRowsAndStreak(_ testCase: Case) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: testCase.zone))

        func noon(_ day: (year: Int, month: Int, day: Int)) throws -> Date {
            try #require(calendar.date(from: DateComponents(
                year: day.year, month: day.month, day: day.day, hour: 12
            )))
        }

        if let skipped = testCase.skippedMidnight {
            // Guards the premise: this zone's midnight doesn't exist on that day.
            let start = calendar.startOfDay(for: try noon(skipped))
            #expect(calendar.component(.hour, from: start) != 0)
        }

        var activeNoons: [Date] = []
        var day = try noon(testCase.firstActiveDay)
        let todayNoon = try noon(testCase.today)
        while day <= todayNoon {
            activeNoons.append(day)
            day = try #require(calendar.date(byAdding: .day, value: 1, to: day))
        }
        let events = activeNoons.map { date in
            UsageEvent(
                id: UUID(),
                createdAt: date,
                appBundleID: "com.example.Editor",
                rawWordCount: 10,
                finalWordCount: 10,
                durationMS: 10_000,
                durationQuality: .captureExact,
                cleanupChanges: .zero,
                cleanupQuality: .exact,
                insertionStatus: .inserted
            )
        }

        let snapshot = UsageAnalyticsCalculator.snapshot(
            events: events,
            coverage: [UsageCoverageInterval(start: activeNoons[0], end: nil)],
            now: todayNoon,
            calendar: calendar,
            months: 6
        )
        let rows = snapshot.dailyUsage

        #expect(rows.last?.date == calendar.startOfDay(for: todayNoon))
        #expect(rows.allSatisfy { calendar.startOfDay(for: $0.date) == $0.date })
        for (earlier, later) in zip(rows, rows.dropFirst()) {
            let expectedNoon = try #require(calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.date(bySettingHour: 12, minute: 0, second: 0, of: earlier.date)!
            ))
            #expect(calendar.isDate(later.date, inSameDayAs: expectedNoon))
        }
        #expect(rows.filter(\.isActive).count == activeNoons.count)
        #expect(rows.filter(\.isInCurrentStreak).count == activeNoons.count)
        #expect(snapshot.currentStreak == activeNoons.count)
        #expect(snapshot.longestKnownStreak == activeNoons.count)
        #expect(snapshot.totalSessions == activeNoons.count)
    }

    @Test("Every zone gets one row per local day up to today throughout 2026")
    func everyZoneEveryDay() throws {
        var failures: [String] = []
        for identifier in ["America/Havana", "America/Santiago", "Africa/Cairo", "Asia/Beirut", "Atlantic/Azores", "America/New_York"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: identifier))
            var now = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12)))
            let end = try #require(calendar.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 12)))
            while now < end {
                let rows = UsageAnalyticsCalculator.snapshot(
                    events: [], coverage: [], now: now, calendar: calendar, months: 6
                ).dailyUsage
                let wholeDays = rows.allSatisfy { calendar.startOfDay(for: $0.date) == $0.date }
                let distinctDays = Set(rows.map(\.date)).count == rows.count
                if rows.last?.date != calendar.startOfDay(for: now) || !wholeDays || !distinctDays {
                    failures.append("\(identifier) \(now)")
                }
                now = try #require(calendar.date(byAdding: .day, value: 1, to: now))
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }
}
