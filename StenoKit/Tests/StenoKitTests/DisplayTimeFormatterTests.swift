import Foundation
import Testing
@testable import StenoKit

@Test("DisplayTimeFormatter renders 12-hour times with AM and PM")
func displayTimeFormatterUsesTwelveHourClockWithAMPM() {
    let calendar = Calendar(identifier: .gregorian)
    let utc = TimeZone(secondsFromGMT: 0)!

    let eveningDate = calendar.date(
        from: DateComponents(
            timeZone: utc,
            year: 2026,
            month: 4,
            day: 18,
            hour: 23,
            minute: 58
        )
    )!
    let morningDate = calendar.date(
        from: DateComponents(
            timeZone: utc,
            year: 2026,
            month: 4,
            day: 18,
            hour: 10,
            minute: 45
        )
    )!

    #expect(DisplayTimeFormatter.string(from: eveningDate, timeZone: utc) == "11:58 PM")
    #expect(DisplayTimeFormatter.string(from: morningDate, timeZone: utc) == "10:45 AM")
}
