import Foundation

/// Times as the margin shows them: 24-hour "10:24".
enum ClockTime {
    static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: timeZone,
            calendar: Calendar(identifier: .gregorian)
        ))
    }
}
