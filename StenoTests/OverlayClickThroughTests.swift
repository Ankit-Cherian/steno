import AppKit
import Testing
@testable import Steno
@testable import StenoKit

/// The island's window is larger than the capsule it draws, for the capsule's shadow and its
/// motion. A click in that transparent margin belongs to the window underneath.
///
/// The window server answers `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` with the
/// window a mouse-down at that point would go to, using the same rules as a real click: it skips
/// a window that ignores mouse events and, unless the window explicitly accepts every mouse event,
/// a window whose pixels there are transparent. Every window here sits below the display's
/// backstop, so nothing shows on screen and no event is posted.
@MainActor
@Suite("Overlay click-through", .serialized)
struct OverlayClickThroughTests {
    static let bottomLevel = Int(CGWindowLevelForKey(.minimumWindow))

    static func plainWindow(_ frame: CGRect, level: Int) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .white
        window.level = NSWindow.Level(rawValue: level)
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.orderFrontRegardless()
        return window
    }

    @Test("A click in the island's transparent margin reaches the window below; the capsule and its Undo keep theirs")
    func marginPassesClicksThrough() async throws {
        let screen = try #require(NSScreen.main)
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.appearance = .grove
        presenter.placementOverride = .capsule
        presenter.setHostedAccessibilityPreferences(.init(
            reduceMotion: false, reduceTransparency: false, increaseContrast: false, preferredBodyPointSize: 13
        ))
        presenter.onUndoDiscard = {}
        presenter.pinNextSessionToDisplay(containing: CGPoint(x: screen.frame.midX, y: screen.frame.midY))
        presenter.prepareWindow()
        let panel = try #require(presenter.hostedEvidenceWindowNumber().flatMap { NSApp.window(withWindowNumber: $0) })
        panel.level = NSWindow.Level(rawValue: Self.bottomLevel + 2)
        defer { presenter.hide() }

        presenter.show(state: .discarded(undoUntil: Date().addingTimeInterval(60)))
        let frame = try #require(presenter.hostedEvidenceWindowFrame())
        let capsule = try #require(presenter.hostedEvidenceCapsuleFrame())
        let undo = try #require(presenter.hostedEvidenceControl(.chip))
        try #require(presenter.hostedEvidenceActionTitle() == "Undo")

        let below = Self.plainWindow(frame.insetBy(dx: -40, dy: -40), level: Self.bottomLevel + 1)
        let above = Self.plainWindow(CGRect(x: frame.maxX + 60, y: frame.minY, width: 8, height: 8), level: Self.bottomLevel + 3)
        defer {
            below.orderOut(nil)
            above.orderOut(nil)
        }
        func window(at point: CGPoint) -> String {
            switch NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: above.windowNumber) {
            case panel.windowNumber: "island"
            case below.windowNumber: "below"
            case let other: "window \(other)"
            }
        }

        // The capsule's centre line, in screen coordinates; the panel's content view is flipped.
        let y = frame.maxY - capsule.midY
        let capsuleCentre = CGPoint(x: frame.minX + capsule.midX, y: y)
        let undoFrame = panel.convertToScreen(undo.convert(undo.bounds, to: nil))
        let undoCentre = CGPoint(x: undoFrame.midX, y: undoFrame.midY)
        let margin = CGPoint(x: frame.minX + 10, y: y)
        try #require(frame.minX + capsule.minX - margin.x >= 10, "the point \(margin) is not in the margin: panel \(frame), capsule \(capsule)")

        // Drawn and known to the window server before anything is asked of the margin.
        try #require(await eventuallyOnMain { window(at: capsuleCentre) == "island" }, "the island never took the capsule's clicks")
        #expect(window(at: undoCentre) == "island", "Undo no longer takes its click")
        #expect(window(at: margin) == "below", "a click 10 pt into the side margin went to the \(window(at: margin))")
        #expect(window(at: CGPoint(x: frame.maxX - 10, y: y)) == "below", "a click in the right margin went elsewhere")
    }
}
