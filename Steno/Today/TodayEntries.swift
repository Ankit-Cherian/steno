import StenoKit
import SwiftUI

/// Which dictations Today lists.
enum TodayEntries {
    /// Every dictation from today, newest first.
    static func todays(_ entries: [TranscriptEntry], now: Date = Date(), calendar: Calendar = .current) -> [TranscriptEntry] {
        let test = isToday(now: now, calendar: calendar)
        return entries.filter { test($0.createdAt) }
    }

    /// Every dictation from today after the latest one, newest first.
    static func earlierToday(_ entries: [TranscriptEntry], now: Date = Date(), calendar: Calendar = .current) -> [TranscriptEntry] {
        let test = isToday(now: now, calendar: calendar)
        return entries.dropFirst().filter { test($0.createdAt) }
    }

    /// A same-day test that asks the calendar about the day once, instead of once per dictation.
    private static func isToday(now: Date, calendar: Calendar) -> (Date) -> Bool {
        if let day = calendar.dateInterval(of: .day, for: now) {
            return { $0 >= day.start && $0 < day.end }
        }
        return { calendar.isDate($0, inSameDayAs: now) }
    }
}
