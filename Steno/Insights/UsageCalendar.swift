import Foundation
import os
import StenoKit

struct UsageCalendarDay: Identifiable, Sendable, Equatable {
    let date: Date
    let sessionCount: Int
    let wordCount: Int
    let durationMS: Int
    let estimatedDurationSessionCount: Int
    let unavailableDurationSessionCount: Int
    let isTracked: Bool
    let isActive: Bool
    let isInCurrentStreak: Bool

    var id: Date { date }
}

/// The six-month window as weeks of days, and how a day is described.
struct UsageCalendar {
    let days: [UsageCalendarDay]
    var calendar: Calendar = .current

    /// "159 words · 1 min 51 s · 6 dictations · part of a 7-day streak", or with `spoken`, for
    /// VoiceOver, "159 words, 1 minute, 51 seconds, 6 dictations, part of a 7-day streak".
    static func dayDetail(_ day: UsageCalendarDay, streak: Int? = nil, spoken: Bool = false) -> String {
        guard day.isTracked else { return "No usage was recorded for this day." }
        guard day.isActive else { return "No dictations." }
        var parts = [
            InsightsFormatting.count(day.wordCount, "word"),
        ]
        if day.durationMS > 0 {
            let estimated = day.estimatedDurationSessionCount > 0
            parts.append(spoken
                ? (estimated ? "about " : "") + InsightsDuration.spokenText(day.durationMS)
                : (estimated ? "≈" : "") + InsightsDuration.minutesSecondsText(day.durationMS))
        }
        parts.append(InsightsFormatting.count(day.sessionCount, "dictation"))
        if day.isInCurrentStreak, let streak, streak > 1 {
            parts.append("part of a \(streak)-day streak")
        }
        return parts.joined(separator: spoken ? ", " : " · ")
    }

    var weeks: [UsageCalendarWeek] {
        // Redrawing Insights recomputed six months of calendar math every time; the result
        // only changes with the days themselves.
        if let cached = Self.weeksMemo.withLock({ $0 }), cached.days == days, cached.calendar == calendar {
            return cached.weeks
        }
        let result = computeWeeks()
        Self.weeksMemo.withLock { $0 = (days, calendar, result) }
        return result
    }

    private static let weeksMemo = OSAllocatedUnfairLock<(days: [UsageCalendarDay], calendar: Calendar, weeks: [UsageCalendarWeek])?>(initialState: nil)

    private func computeWeeks() -> [UsageCalendarWeek] {
        guard
            let firstDay = days.map(\.date).min(),
            let lastDay = days.map(\.date).max(),
            let firstWeek = calendar.dateInterval(of: .weekOfYear, for: firstDay)?.start,
            let lastWeek = calendar.dateInterval(of: .weekOfYear, for: lastDay)?.start
        else { return [] }

        let normalizedDays = Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0.date), $0) })
        let rangeStart = calendar.startOfDay(for: firstDay)
        let rangeEnd = calendar.startOfDay(for: lastDay)
        var result: [UsageCalendarWeek] = []
        var weekStart = firstWeek
        while weekStart <= lastWeek {
            let cells = (0..<7).map { dayOffset -> UsageCalendarCell in
                let date = UsageAnalyticsCalculator.dayStart(offsetBy: dayOffset, from: weekStart, calendar: calendar) ?? weekStart
                return UsageCalendarCell(date: date, usage: normalizedDays[date], isInRange: date >= rangeStart && date <= rangeEnd)
            }
            result.append(UsageCalendarWeek(id: weekStart, cells: cells))
            guard let next = UsageAnalyticsCalculator.dayStart(offsetBy: 7, from: weekStart, calendar: calendar), next > weekStart else { break }
            weekStart = next
        }
        return result
    }
}

struct UsageCalendarWeek: Identifiable, Sendable {
    let id: Date
    let cells: [UsageCalendarCell]
}

struct UsageCalendarCell: Identifiable, Sendable {
    let date: Date
    let usage: UsageCalendarDay?
    let isInRange: Bool

    var id: Date { date }
}
