import AppKit
import SwiftUI

/// Opens the Settings window from anywhere in the app, including AppKit callers such as the menu bar.
///
/// Settings is a `Window` scene so it can be opened from code on macOS 13. The scene's
/// `OpenWindowAction` is captured once from a view at launch and stored here.
@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    static let windowID = "settings"
    /// The main window's scene ID, so the menu bar can reopen it after it was closed.
    static let mainWindowID = "main"

    /// The section the next opening should show. The Settings window clears it after reading.
    @Published var requestedSection: SettingsSection?

    private var openWindow: OpenWindowAction?

    func install(_ action: OpenWindowAction) {
        openWindow = action
    }

    func open(_ section: SettingsSection? = nil) {
        if let section {
            requestedSection = section
        }
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: Self.windowID)
    }

    #if DEBUG
    /// Opens Settings without bringing the app forward, for the performance tour.
    func openWithoutActivating(_ section: SettingsSection) {
        requestedSection = section
        openWindow?(id: Self.windowID)
    }
    #endif

    /// Brings the main window forward, opening it again if it was closed.
    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: Self.isMainWindow) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: Self.mainWindowID)
        }
    }

    private static func isMainWindow(_ window: NSWindow) -> Bool {
        guard !(window is NSPanel), window.canBecomeMain else { return false }
        return window.identifier?.rawValue.hasPrefix(windowID) != true
    }
}
