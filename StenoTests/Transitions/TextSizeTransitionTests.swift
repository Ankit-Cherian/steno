import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// The windows follow the text size set in System Settings, as the island does, and pick up a
/// change when Steno is next brought to the front.
@Suite("System text size", .serialized)
@MainActor
struct TextSizeTransitionTests {
    typealias F = TransitionFixtures

    /// The body size System Settings reports, changed by a test.
    @MainActor
    final class BodySize {
        var points = SystemTextSize.baselineBodyPointSize
    }

    @Test("Body sizes map to the nearest text-size step, never below the default", arguments: [
        (CGFloat(11), DynamicTypeSize.large), (13, .large), (14, .xLarge), (16, .xxLarge), (17.5, .xxxLarge), (21, .accessibility1),
    ])
    func steps(points: CGFloat, step: DynamicTypeSize) {
        #expect(SystemTextSize.step(forBodyPointSize: points) == step)
    }

    @Test("Today's text grows with a larger system text size, and again when the setting changes while Steno is away")
    func windowFollowsSystemTextSize() async throws {
        let size = BodySize()
        let center = NotificationCenter()
        let source = SystemTextSize(read: { size.points }, notificationCenter: center)
        let controller = F.sampleController()
        let host = TransitionHost(controller: controller) {
            GroveRenderHarness.window(.today, controller: controller) { GroveTodayView() }
                .environment(\.systemTextSize, source)
        }
        defer { host.close() }
        func dictateHeight() -> CGFloat { host.node(named: "Dictate")?.screenFrame.height ?? 0 }
        func dateHeight() -> CGFloat { host.node { $0.role == "AXHeading" }?.screenFrame.height ?? 0 }
        await host.settle { dictateHeight() > 0 && dateHeight() > 0 }
        let standard = (dictateHeight(), dateHeight())

        size.points = 17.5
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(await host.settle { dateHeight() > standard.1 + 2 },
                "the date stayed \(dateHeight()) pt tall at a larger system text size (was \(standard.1))")
        #expect(dictateHeight() > standard.0, "the stage stayed \(dictateHeight()) pt tall (was \(standard.0))")

        size.points = SystemTextSize.baselineBodyPointSize
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(await host.settle { abs(dateHeight() - standard.1) < 0.5 }, "the date did not return to \(standard.1)")
    }

    @Test("A text size set further out still holds when the system's is smaller")
    func outerSizeHolds() async throws {
        let controller = F.sampleController()
        let knobs = TransitionKnobs()
        knobs.textSize = .xxLarge
        let host = TransitionHost(controller: controller, knobs: knobs) {
            GroveRenderHarness.window(.today, controller: controller) { GroveTodayView() }
        }
        defer { host.close() }
        func dateHeight() -> CGFloat { host.node { $0.role == "AXHeading" }?.screenFrame.height ?? 0 }
        await host.settle { dateHeight() > 0 }
        let large = dateHeight()
        knobs.textSize = .large
        #expect(await host.settle { dateHeight() < large - 2 }, "the date stayed \(dateHeight()) pt tall")
    }
}
