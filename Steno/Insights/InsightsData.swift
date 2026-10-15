import StenoKit
import SwiftUI

/// One app in Where You Dictate: its dictations, words and time.
struct AppUsageDisplay: Identifiable, Equatable {
    let appBundleID: String
    let sessionCount: Int
    let wordCount: Int
    let durationMS: Int
    let estimatedDurationSessionCount: Int
    let unavailableDurationSessionCount: Int

    var id: String { appBundleID }
}

/// What Insights shows, read from the metadata ledger, never from dictation text.
enum InsightsData {
    static func calendarDays(_ snapshot: UsageAnalyticsSnapshot) -> [UsageCalendarDay] {
        snapshot.dailyUsage.map { day in
            UsageCalendarDay(date: day.date, sessionCount: day.sessionCount, wordCount: day.wordCount,
                             durationMS: day.durationMS,
                             estimatedDurationSessionCount: day.estimatedDurationSessionCount,
                             unavailableDurationSessionCount: day.unavailableDurationSessionCount,
                             isTracked: day.isTracked, isActive: day.isActive, isInCurrentStreak: day.isInCurrentStreak)
        }
    }

    static func appUsage(_ snapshot: UsageAnalyticsSnapshot) -> [AppUsageDisplay] {
        snapshot.topApps.map { app in
            AppUsageDisplay(appBundleID: app.appBundleID, sessionCount: app.sessionCount, wordCount: app.wordCount,
                            durationMS: app.durationMS,
                            estimatedDurationSessionCount: app.estimatedDurationSessionCount,
                            unavailableDurationSessionCount: app.unavailableDurationSessionCount)
        }
    }
}
