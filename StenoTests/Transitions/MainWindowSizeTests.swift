import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// The main window's size as the app builds it: a titled window with the unified toolbar,
/// holding the real window content.
@Suite("Main window size", .serialized)
@MainActor
struct MainWindowSizeTests {
    /// A titled window that stays where it is put, far from every display.
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private func settle(_ window: NSWindow, timeout: Duration = .seconds(5), until condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(16))
            if condition() { return true }
        } while clock.now < deadline
        return condition()
    }

    private func shrink(_ window: NSWindow) async -> CGSize {
        window.setFrame(CGRect(origin: window.frame.origin, size: CGSize(width: 400, height: 300)), display: true)
        _ = await settle(window, timeout: .milliseconds(400)) { false }
        return window.frame.size
    }

    @Test("The window opens at 1,120 × 760 and cannot be made smaller than 960 × 640, before and after onboarding")
    func minimumHoldsAndDefaultOpens() async throws {
        TransitionHost.enableAccessibilityTree()
        let controller = TransitionFixtures.sampleController()
        let ideal = CGSize(width: MainWindowMetrics.idealWidth, height: MainWindowMetrics.idealHeight)
        let window = OffscreenWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 100, height: 100),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                     backing: .buffered, defer: false)
        window.setFrame(CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: ideal), display: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        let hosting = NSHostingView(rootView: AppWindowContent(controller: controller, appDelegate: AppDelegate()))
        if #available(macOS 14.0, *) { hosting.sceneBridgingOptions = [.toolbars] }
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        #expect(await settle(window) { window.toolbar?.items.isEmpty == false && window.titleVisibility == .hidden },
                "the library did not show under its toolbar")
        _ = await settle(window, timeout: .milliseconds(300)) { false }
        #expect(window.frame.size == ideal, "the window opened at \(window.frame.size)")

        let minimum = CGSize(width: MainWindowMetrics.minWidth, height: MainWindowMetrics.minHeight)
        let shrunk = await shrink(window)
        #expect(shrunk == minimum, "the window shrank to \(shrunk)")

        controller.preferences.general.showOnboarding = true
        _ = await settle(window, timeout: .milliseconds(500)) { false }
        controller.preferences.general.showOnboarding = false
        _ = await settle(window, timeout: .milliseconds(500)) { false }
        let again = await shrink(window)
        #expect(again == minimum, "after onboarding the window shrank to \(again)")
    }
}
