import Foundation
import Testing
@testable import Steno

@Test("Insights counts use system plural and number formatting")
func insightsFormattingUsesSystemFormatting() {
    let locale = Locale(identifier: "en_US")
    #expect(InsightsFormatting.count(1, "session", locale: locale) == "1 session")
    #expect(InsightsFormatting.count(1_234, "session", locale: locale) == "1,234 sessions")
    #expect(InsightsFormatting.compactCount(999, locale: locale) == "999")
    #expect(InsightsFormatting.compactCount(1_234, locale: locale) == "1.2K")
    #expect(InsightsFormatting.compactCount(999_950, locale: locale) == "1M")
    #expect(InsightsFormatting.compactDuration(milliseconds: 1_234 * 3_600_000, locale: locale) == "1,234h")
    #expect(InsightsFormatting.compactDuration(milliseconds: 90 * 60_000, locale: locale) == "1h 30m")
    #expect(
        InsightsFormatting.durationDetail(estimatedSessions: 0, unavailableSessions: 1, locale: locale)
            == "1 session without a saved time"
    )
    #expect(
        InsightsFormatting.durationDetail(estimatedSessions: 1, unavailableSessions: 0, locale: locale)
            == "1 imported duration estimated"
    )
}
