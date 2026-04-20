import AppKit
import SwiftUI

struct WindowConfigurator: NSViewRepresentable {
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
        // The custom tab buttons live in the title bar region, so broad
        // background dragging makes small pointer movement swallow clicks.
        window.isMovableByWindowBackground = false
        window.toolbar = nil
        window.backgroundColor = .clear
        window.isOpaque = false
        window.minSize = NSSize(width: StenoDesign.windowMinWidth, height: StenoDesign.windowMinHeight)
        if window.frame.width < StenoDesign.windowMinWidth || window.frame.height < StenoDesign.windowMinHeight {
            window.setContentSize(NSSize(width: StenoDesign.windowIdealWidth, height: StenoDesign.windowIdealHeight))
        }
        window.setFrameAutosaveName("StenoRedesignWindow")

        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}
