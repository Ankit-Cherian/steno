import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

@Suite("Grove Insights rules")
@MainActor
struct GroveInsightsRulesTests {
    @Test("A day's cell gets one of four steps by its share of the busiest day, and empty is neutral")
    func dayLevels() {
        #expect(GroveDayGrid.level(words: 0, maximum: 100) == 0)
        #expect(GroveDayGrid.level(words: 1, maximum: 100) == 1)
        #expect(GroveDayGrid.level(words: 25, maximum: 100) == 1)
        #expect(GroveDayGrid.level(words: 26, maximum: 100) == 2)
        #expect(GroveDayGrid.level(words: 75, maximum: 100) == 3)
        #expect(GroveDayGrid.level(words: 100, maximum: 100) == 4)
        #expect(GroveDayGrid.level(words: 5, maximum: 0) == 4)
    }

    @Test("Time is said in words")
    func spokenDuration() {
        #expect(GroveInsightsSummary.spokenDuration(226 * 60_000) == "3 hours 46 minutes")
        #expect(GroveInsightsSummary.spokenDuration(120 * 60_000) == "2 hours")
        #expect(GroveInsightsSummary.spokenDuration(65 * 60_000) == "1 hour 5 minutes")
        #expect(GroveInsightsSummary.spokenDuration(45 * 60_000) == "45 minutes")
        #expect(GroveInsightsSummary.spokenDuration(60_000) == "1 minute")
        #expect(GroveInsightsSummary.wordsText(1) == "1 word")
    }

    @Test("The opening sentence counts this month and subtracts speaking from typing at 40 words a minute")
    func openingSentence() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 15))!
        let day = { (offset: Int) in calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))! }
        // 4,000 words spoken in 30 minutes, this month; last month's words do not count.
        let snapshot = Self.snapshot(days: [
            Self.day(day(-20), words: 9_000, minutes: 60), Self.day(day(-3), words: 1_000, minutes: 8), Self.day(day(0), words: 3_000, minutes: 22)
        ], now: now)
        let summary = GroveInsightsSummary.make(snapshot: snapshot, now: now, calendar: calendar)
        #expect(summary.scope == .thisMonth)
        #expect(summary.words == 4_000)
        // 4,000 words typed at 40 a minute is 100 minutes; spoken in 30. Seventy minutes saved.
        #expect(summary.timeSavedMS == 70 * 60_000)
        #expect(GroveInsightsSummary.plain(summary.opening) == "4,000 words so far this month, about 1 hour 10 minutes of typing saved.")
        #expect(summary.rangeLabel == "October 1 to 7")
        #expect(summary.busiestDay?.words == 9_000)
    }

    @Test("Without a month of words the sentence counts everything, and without a measurable gain it says no time")
    func openingFallbacks() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 9))!
        let lastMonth = calendar.date(byAdding: .day, value: -5, to: calendar.startOfDay(for: now))!
        let snapshot = Self.snapshot(days: [Self.day(lastMonth, words: 800, minutes: 10)], now: now)
        let summary = GroveInsightsSummary.make(snapshot: snapshot, now: now, calendar: calendar)
        #expect(summary.scope == .allTime)
        #expect(summary.rangeLabel == "All time")
        #expect(GroveInsightsSummary.plain(summary.opening).hasPrefix("800 words in all"))
        // Slower than typing: nothing saved, so no clause about saved time.
        let slow = Self.snapshot(days: [Self.day(calendar.startOfDay(for: now), words: 100, minutes: 10)], now: now)
        let slowSummary = GroveInsightsSummary.make(snapshot: slow, now: now, calendar: calendar)
        #expect(slowSummary.timeSavedMS == nil)
        #expect(GroveInsightsSummary.plain(slowSummary.opening) == "100 words so far this month.")
        #expect(GroveInsightsSummary.rangeLabel(scope: .thisMonth, now: now, calendar: calendar) == "October 1")
    }

    @Test("The line under it names only what the ledger supports")
    func followUp() {
        var summary = GroveInsightsSummary(scope: .thisMonth, words: 10, timeSavedMS: nil, paceWordsPerMinute: 146,
                                           paceIsEstimate: false, streakDays: 18, busiestDay: nil, rangeLabel: "")
        #expect(GroveInsightsSummary.plain(summary.followUp)
            == "You speak at 146 words a minute, and you’ve dictated 18 days in a row. All of it was heard and written on this Mac.")
        summary.streakDays = 1
        #expect(GroveInsightsSummary.plain(summary.followUp) == "You speak at 146 words a minute. All of it was heard and written on this Mac.")
        summary.paceWordsPerMinute = nil
        #expect(GroveInsightsSummary.plain(summary.followUp) == "All of it was heard and written on this Mac.")
        summary.streakDays = 4
        #expect(GroveInsightsSummary.plain(summary.followUp) == "You’ve dictated 4 days in a row. All of it was heard and written on this Mac.")
    }

    @Test("Apps are ranked by words, ties by name, and the empty are left out")
    func appRanking() {
        func app(_ id: String, _ words: Int) -> AppUsageDisplay {
            AppUsageDisplay(appBundleID: id, sessionCount: 1, wordCount: words, durationMS: 0,
                            estimatedDurationSessionCount: 0, unavailableDurationSessionCount: 0)
        }
        let ranked = GroveAppWordRows.ranked([app("b", 10), app("c", 0), app("a", 10), app("d", 30)])
        #expect(ranked.map(\.appBundleID) == ["d", "a", "b"])
    }

    @Test("An app's share is a whole percent of every counted word")
    func appShare() {
        #expect(GroveAppWordRows.share(96_168, of: 119_717) == "80%")
        #expect(GroveAppWordRows.share(3_286, of: 119_717) == "3%")
        #expect(GroveAppWordRows.share(400, of: 119_717) == "<1%")
        #expect(GroveAppWordRows.share(0, of: 0) == "0%")
    }

    private static func day(_ date: Date, words: Int, minutes: Int) -> DailyUsage {
        DailyUsage(date: date, sessionCount: 1, wordCount: words, durationMS: minutes * 60_000, cleanupChanges: 0,
                   estimatedDurationSessionCount: 0, unavailableDurationSessionCount: 0, isTracked: true, isActive: true,
                   isInCurrentStreak: false)
    }

    private static func snapshot(days: [DailyUsage], now: Date) -> UsageAnalyticsSnapshot {
        let words = days.reduce(0) { $0 + $1.wordCount }
        let duration = days.reduce(0) { $0 + $1.durationMS }
        var snapshot = UsageAnalyticsSnapshot.empty
        snapshot.totalSessions = days.count
        snapshot.totalWords = words
        snapshot.totalDurationMS = duration
        snapshot.averageWordsPerMinute = duration > 0 ? Double(words) / (Double(duration) / 60_000) : 0
        snapshot.exactDurationSessionCount = days.count
        snapshot.dailyUsage = days
        return snapshot
    }
}

/// Draws Grove's Insights in every state to PNG.
@Suite("Grove Insights renders", .serialized)
@MainActor
struct GroveInsightsRenderingTests {
    typealias Variant = GroveRenderHarness.Variant
    typealias Harness = GroveRenderHarness

    @Test("Insights with a lot of use", arguments: Variant.allCases)
    func many(variant: Variant) async throws {
        let controller = Harness.sampleController(variant)
        try await Harness.write(ContentView(initialTab: .insights), controller: controller, variant: variant,
                                name: "insights-many-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("Insights with a few weeks of use", arguments: [Variant.light, .dark])
    func few(variant: Variant) async throws {
        let controller = Harness.sampleController(variant)
        controller.usageAnalyticsSnapshot = WindowSampleData.usageSnapshot(weeks: Array(repeating: 0, count: 23) + [3, 6, 2])
        try await Harness.write(ContentView(initialTab: .insights), controller: controller, variant: variant,
                                name: "insights-few-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("Insights when counts began partway through the calendar", arguments: [Variant.light, .dark])
    func partlyCounted(variant: Variant) async throws {
        let controller = Harness.sampleController(variant)
        let weeks = Array(repeating: 0, count: 11) + Array(WindowSampleData.weeklyMinutes.suffix(15))
        controller.usageAnalyticsSnapshot = WindowSampleData.usageSnapshot(weeks: weeks, countedWeeks: 15)
        try await Harness.write(ContentView(initialTab: .insights), controller: controller, variant: variant,
                                name: "insights-partly-counted-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("Insights before any dictation", arguments: [Variant.light, .dark])
    func empty(variant: Variant) async throws {
        let controller = Harness.sampleController(variant)
        controller.usageAnalyticsSnapshot = WindowSampleData.usageSnapshot(weeks: [])
        try await Harness.write(ContentView(initialTab: .insights), controller: controller, variant: variant,
                                name: "insights-empty-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("Insights while loading")
    func loading() async throws {
        let controller = Harness.sampleController(.light)
        controller.usageAnalyticsSnapshot = .empty
        controller.isLoadingUsageAnalytics = true
        try await Harness.write(ContentView(initialTab: .insights), controller: controller, variant: .light,
                                name: "insights-loading-light")
        await controller.teardownAndWait()
    }

    @Test("Insights that could not load", arguments: [Variant.light, .dark])
    func error(variant: Variant) async throws {
        let controller = Harness.sampleController(variant)
        controller.usageAnalyticsSnapshot = .empty
        controller.usageAnalyticsError = "The usage file couldn’t be read."
        try await Harness.write(ContentView(initialTab: .insights), controller: controller, variant: variant,
                                name: "insights-error-\(variant.rawValue)")
        await controller.teardownAndWait()
    }

    @Test("The minimum window")
    func minimum() async throws {
        let controller = Harness.sampleController(.light)
        try await Harness.write(ContentView(initialTab: .insights), controller: controller, variant: .light,
                                size: Harness.minimumSize, name: "insights-minimum-light")
        await controller.teardownAndWait()
    }

    @Test("A large window")
    func large() async throws {
        let controller = Harness.sampleController(.dark)
        try await Harness.write(ContentView(initialTab: .insights), controller: controller, variant: .dark,
                                size: CGSize(width: 1440, height: 1000), name: "insights-large-dark")
        await controller.teardownAndWait()
    }
}
