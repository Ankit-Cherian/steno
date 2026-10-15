import AppKit
import StenoKit
import SwiftUI

/// Replaces About Steno, so the panel shows the icon the Dock shows. A stored
/// `stenoDesignDirection`, `stenoGroveMark`, `stenoGroveIdentity`, `stenoGroveIslandStyle` or
/// `stenoGroveStageStyle` from an earlier build is never read.
struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Steno") { GroveBrandApplier.showAbout() }
        }
    }
}

/// Carries the tile to what SwiftUI does not draw: the Dock icon and the About panel's icon. The
/// Dock shows the tile with the voice quill drawn from `BrandMark` at runtime; Finder and the
/// bundle show the bundle's icon, the same tile generated from the same definition.
@MainActor
final class GroveBrandApplier {
    private let setDockIcon: (NSImage?) -> Void

    init(setDockIcon: @escaping (NSImage?) -> Void = { NSApp.applicationIconImage = $0 }) {
        self.setDockIcon = setDockIcon
    }

    /// Sets the Dock icon.
    func start() {
        setDockIcon(Self.appIcon)
    }

    /// The tile with the voice quill, drawn from the one mark definition on the macOS icon grid:
    /// the 824 tile and its shadow in a 1024 canvas, as the bundle's icon is.
    static let appIcon: NSImage? = {
        let tile = RoundedRectangle(cornerRadius: BrandIconArtwork.cornerRadius(px: 1024), style: .continuous)
            .path(in: BrandIconArtwork.tileRect(px: 1024)).cgPath
        guard let image = BrandIconArtwork.image(px: 1024, colors: .green, tileShape: tile) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 1024, height: 1024))
    }()

    /// Opens the standard About panel with the icon the Dock shows. The panel does not pick up a
    /// runtime Dock icon on its own, so it is passed explicitly.
    static func showAbout() {
        let icon = appIcon ?? NSImage(named: NSImage.applicationIconName)
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let icon { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }
}
