import AppKit
import SwiftUI

struct WindowConfigurator: NSViewRepresentable {
    var savesWindowFrame = true
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)

        DispatchQueue.main.async {
            guard let window = view.window else { return }
            configure(window: window)
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            configure(window: window)
        }
    }

    private func configure(window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Keep background clicks available to controls; the native title bar
        // remains the window's drag region.
        window.isMovableByWindowBackground = false
        window.toolbar = nil
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.minSize = NSSize(width: StenoDesign.windowMinWidth, height: StenoDesign.windowMinHeight)
        if window.frame.width < StenoDesign.windowMinWidth || window.frame.height < StenoDesign.windowMinHeight {
            window.setContentSize(NSSize(width: StenoDesign.windowIdealWidth, height: StenoDesign.windowIdealHeight))
        }
        if savesWindowFrame {
            window.setFrameAutosaveName("StenoRedesignWindow")
        }

        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}
