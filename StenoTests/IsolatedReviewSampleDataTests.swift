import Foundation
import Testing
@testable import Steno
@testable import StenoKit

/// The isolated preview shows the window's sample History, records and usage, and nothing real.
@Suite("Isolated preview sample data")
@MainActor
struct IsolatedReviewSampleDataTests {
    @Test("Populated preview shows the sample dictations with the latest one's record, and usage")
    func populated() throws {
        let controller = IsolatedAppPreview.makeController(populated: false)
        defer { controller.teardown() }
        IsolatedReviewControls.stage(.ready, on: controller)

        let latest = try #require(controller.recentEntries.first { $0.id == WindowSampleData.latestID })
        #expect(latest.record?.microphoneName == "MacBook Pro Microphone")
        #expect(controller.recentEntries.count == WindowSampleData.entries().count)
        #expect(controller.usageAnalyticsSnapshot.totalSessions > 0)
    }

    @Test("Empty and Recovery previews keep only what they say")
    func emptyAndRecovery() {
        let controller = IsolatedAppPreview.makeController(populated: false)
        defer { controller.teardown() }
        IsolatedReviewControls.stage(.empty, on: controller)
        #expect(controller.recentEntries.isEmpty)

        IsolatedReviewControls.stage(.recovery, on: controller)
        #expect(controller.recentEntries.map(\.id) == [WindowSampleData.bookingID])
        #expect(controller.recentEntries.first?.insertionStatus == .failed)
    }
}
