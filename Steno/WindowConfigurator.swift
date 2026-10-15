import AppKit
import SwiftUI

/// Window settings SwiftUI does not cover on macOS 13: a unified toolbar with a hidden title,
/// the minimum size, and the saved frame.
///
/// They are applied once the view is in its window, and only where the window differs. Every
/// hosting view in the window, each toolbar item's included, observes some of them, and a change
/// notification that reaches one SwiftUI is tearing down crashes in SwiftUI. Rewriting them on
/// every update did that when onboarding replaced the library and its toolbar items.
struct WindowConfigurator: NSViewRepresentable {
    var savesWindowFrame = true

    func makeNSView(context: Context) -> NSView {
        WindowSettingsView { window in
            window.setIfChanged(\.titleVisibility, .hidden)
            // Keep background clicks available to controls; the toolbar is the drag region.
            window.setIfChanged(\.isMovableByWindowBackground, false)
            window.setIfChanged(\.isOpaque, true)
            window.setIfChanged(\.titlebarAppearsTransparent, false)
            window.setIfChanged(\.toolbarStyle, .unified)
            let minimum = NSSize(width: MainWindowMetrics.minWidth, height: MainWindowMetrics.minHeight)
            window.setIfChanged(\.minSize, minimum)
            window.holdMinimumFrame(minimum)
            if window.frame.width < minimum.width || window.frame.height < minimum.height {
                window.setContentSize(NSSize(width: MainWindowMetrics.idealWidth, height: MainWindowMetrics.idealHeight))
            }
            #if DEBUG
            if IsolatedAppPreview.isRequested, !IsolatedAppPreview.isTestHost {
                window.setIfChanged(\.title, IsolatedAppPreview.windowTitle)
            }
            #endif
            if savesWindowFrame, window.frameAutosaveName.isEmpty {
                window.setFrameAutosaveName("StenoRedesignWindow")
            }
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Applies `configure` to the window the view joins, after the update that added it.
final class WindowSettingsView: NSView {
    private let configure: (NSWindow) -> Void

    init(configure: @escaping (NSWindow) -> Void) {
        self.configure = configure
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            self?.configure(window)
        }
    }
}

extension NSWindow {
    private static let minimumFrameID = "steno.window.minimumFrame"

    /// Keeps the frame at least `minimum` with required constraints on the content view.
    /// `minSize` alone does not hold: SwiftUI sets it again from the content's own minimum,
    /// about 450 × 95, whenever the content changes. A constraint is not a window setting, so
    /// it sends no change notification, and it leaves the opening size alone.
    func holdMinimumFrame(_ minimum: NSSize) {
        guard let content = contentView,
              !content.constraints.contains(where: { $0.identifier == Self.minimumFrameID }) else { return }
        let chrome = CGSize(width: frame.width - content.frame.width, height: frame.height - content.frame.height)
        let constraints = [
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum.width - chrome.width),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: minimum.height - chrome.height),
        ]
        for constraint in constraints { constraint.identifier = Self.minimumFrameID }
        NSLayoutConstraint.activate(constraints)
    }

    /// Writes a setting only when it differs, so observers hear of real changes only.
    func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<NSWindow, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}
