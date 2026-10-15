import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// The main window as the app builds it, a titled window with the unified toolbar, switched
/// between the library and onboarding the way the first run and Settings switch it.
///
/// Every hosting view in a window, a toolbar item's included, observes the window's settings.
/// A change notification that reaches one SwiftUI is tearing down, as the library's toolbar
/// items are when onboarding replaces the library, crashes in SwiftUI
/// (`LazyPreventsWindowDragFeature.update(host:)`). So the switch must change no setting.
@Suite("Main window onboarding swap", .serialized)
@MainActor
struct MainWindowOnboardingSwapTests {
    /// A titled window that stays where it is put, far from every display.
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// Every change notification the window sends for the settings the window configurator owns.
    private final class SettingChanges: NSObject {
        static let keys = ["movableByWindowBackground", "titleVisibility", "titlebarAppearsTransparent",
                           "toolbarStyle", "opaque", "minSize", "title"]
        private(set) var keys: [String] = []
        private let window: NSWindow

        init(_ window: NSWindow) {
            self.window = window
            super.init()
            for key in Self.keys { window.addObserver(self, forKeyPath: key, context: nil) }
        }

        func stop() {
            for key in Self.keys { window.removeObserver(self, forKeyPath: key) }
        }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                   change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            keys.append(keyPath ?? "")
        }
    }

    private func names(in view: NSView) -> [String] {
        var result: [String] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: NSObject, depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = TransitionHost.Node(object: object)
            result.append(node.identifier.isEmpty ? node.name : node.identifier)
            for child in node.children { walk(child, depth: depth + 1) }
        }
        walk(view, depth: 0)
        return result
    }

    private func settle(_ window: NSWindow, timeout: Duration = .seconds(5), until condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(16))
            if condition() { return true }
        } while clock.now < deadline
        return condition()
    }

    @Test("Showing and closing onboarding over the library changes none of the window's settings")
    func swapChangesNoWindowSetting() async throws {
        TransitionHost.enableAccessibilityTree()
        let controller = TransitionFixtures.sampleController()
        let window = OffscreenWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 1000, height: 720),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                     backing: .buffered, defer: false)
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

        let library = { names(in: hosting).contains("today.start") && (window.toolbar?.items.isEmpty == false) }
        let onboarding = { names(in: hosting).contains("onboarding.start") }
        #expect(await settle(window) { library() && window.titleVisibility == .hidden },
                "the library did not show under its toolbar: \(names(in: hosting).prefix(20))")

        let changes = SettingChanges(window)
        defer { changes.stop() }
        for round in 1...6 {
            controller.preferences.general.showOnboarding = true
            #expect(await settle(window) { onboarding() && !library() }, "round \(round): onboarding did not replace the library")
            controller.preferences.general.showOnboarding = false
            #expect(await settle(window) { library() && !onboarding() }, "round \(round): the library did not come back")
        }
        // Let any configuration scheduled by the last switch run.
        _ = await settle(window, timeout: .milliseconds(300)) { false }
        #expect(changes.keys == [])
    }
}
