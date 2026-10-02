#if os(macOS)
import AppKit
import Foundation

/// Decides whether an insertion aimed at Steno's own app has anywhere to go.
///
/// Dictation started from Steno's window targets Steno itself. Typed or pasted
/// text lands there only when one of its text fields has keyboard focus;
/// otherwise AppKit drops it and plays the alert sound. Every other target is
/// answered from the bundle identifier alone, without any further work.
public struct OwnAppTextFocus: Sendable {
    private let ownBundleIdentifier: String?
    private let focusAcceptsText: @MainActor @Sendable () -> Bool

    init(
        ownBundleIdentifier: String?,
        focusAcceptsText: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.ownBundleIdentifier = ownBundleIdentifier
        self.focusAcceptsText = focusAcceptsText
    }

    /// Reads the focus of this process's own windows.
    public static let live = OwnAppTextFocus(
        ownBundleIdentifier: Bundle.main.bundleIdentifier,
        focusAcceptsText: { focusedResponderAcceptsText() }
    )

    /// True only when `target` is this app and nothing in it can take text.
    func refusesInsertion(into target: AppContext) async -> Bool {
        guard let ownBundleIdentifier,
              target.bundleIdentifier == ownBundleIdentifier else {
            return false
        }
        return await !focusAcceptsText()
    }

    /// The key window's first responder, or, while the app is in the
    /// background, that of the window that becomes key when it returns.
    @MainActor
    static func focusedResponderAcceptsText() -> Bool {
        guard let app = NSApp else { return true }
        let window = app.keyWindow
            ?? app.mainWindow
            ?? app.orderedWindows.first { $0.isVisible && $0.canBecomeMain }
        return acceptsText(window?.firstResponder)
    }

    /// A text field's field editor and an editable text view take text. A
    /// window, a button or a list does not. An unknown text input client is
    /// assumed to take text, so it keeps inserting as before.
    @MainActor
    static func acceptsText(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if let textView = responder as? NSTextView {
            return textView.isEditable
        }
        return responder is NSTextInputClient
    }
}
#endif
