import Foundation
import Testing
@testable import Steno

@Test("Insights counts use system plural and number formatting")
func insightsFormattingUsesSystemFormatting() {
    let locale = Locale(identifier: "en_US")
    #expect(InsightsFormatting.count(1, "session", locale: locale) == "1 session")
    #expect(InsightsFormatting.count(1_234, "session", locale: locale) == "1,234 sessions")
}

@Test("A calendar day reads to VoiceOver in words, and its tooltip keeps the short form")
@MainActor
func spokenCalendarDay() {
    let day = UsageCalendarDay(date: Date(timeIntervalSince1970: 1_790_000_000), sessionCount: 6, wordCount: 159,
                               durationMS: 111_000, estimatedDurationSessionCount: 1, unavailableDurationSessionCount: 0,
                               isTracked: true, isActive: true, isInCurrentStreak: true)
    #expect(UsageCalendar.dayDetail(day, streak: 7) == "159 words · ≈1 min 51 s · 6 dictations · part of a 7-day streak")
    #expect(UsageCalendar.dayDetail(day, streak: 7, spoken: true)
            == "159 words, about 1 minute, 51 seconds, 6 dictations, part of a 7-day streak")
    #expect(InsightsDuration.spokenText(7_500_000) == "2 hours, 5 minutes")
    let quiet = UsageCalendarDay(date: day.date, sessionCount: 0, wordCount: 0, durationMS: 0, estimatedDurationSessionCount: 0,
                                 unavailableDurationSessionCount: 0, isTracked: true, isActive: false, isInCurrentStreak: false)
    #expect(UsageCalendar.dayDetail(quiet) == "No dictations.")
}
