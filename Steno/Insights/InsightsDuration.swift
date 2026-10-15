import Foundation

/// Dictated time as text, for the calendar's day line.
enum InsightsDuration {
    static func minutesText(_ milliseconds: Int) -> String {
        let minutes = Int((Double(milliseconds) / 60_000).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours.formatted()) h" : "\(hours.formatted()) h \(rest) min"
    }

    static func minutesSecondsText(_ milliseconds: Int) -> String {
        let seconds = Int((Double(milliseconds) / 1_000).rounded())
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3_600 {
            let rest = seconds % 60
            return rest == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(rest) s"
        }
        return minutesText(milliseconds)
    }

    /// "1 minute, 51 seconds" or "2 hours, 5 minutes": a duration in words, for VoiceOver.
    static func spokenText(_ milliseconds: Int) -> String {
        let seconds = Int((Double(milliseconds) / 1_000).rounded())
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds < 3_600 ? [.minute, .second] : [.hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(seconds)) ?? minutesSecondsText(milliseconds)
    }
}
