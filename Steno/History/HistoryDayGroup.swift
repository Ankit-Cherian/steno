import StenoKit
import SwiftUI

/// Dictations grouped by day for the History list.
struct HistoryDayGroup: Identifiable, Equatable {
    var title: String
    var entries: [TranscriptEntry]
    var id: String { title + (entries.first?.id.uuidString ?? "") }

    static func groups(_ entries: [TranscriptEntry], now: Date = Date(), calendar: Calendar = .current) -> [HistoryDayGroup] {
        var groups: [HistoryDayGroup] = []
        // Calendar work runs once per day, not once per dictation: an entry inside the current
        // group's day joins it with two date comparisons.
        var day: DateInterval?
        for entry in entries {
            if let day, day.contains(entry.createdAt), entry.createdAt < day.end {
                groups[groups.count - 1].entries.append(entry)
                continue
            }
            let title = dayTitle(entry.createdAt, now: now, calendar: calendar)
            day = calendar.dateInterval(of: .day, for: entry.createdAt)
            if groups.last?.title == title {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append(HistoryDayGroup(title: title, entries: [entry]))
            }
        }
        return groups
    }

    static func dayTitle(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear
            ? date.formatted(.dateTime.weekday(.wide).month(.wide).day())
            : date.formatted(.dateTime.month(.wide).day().year())
    }
}
