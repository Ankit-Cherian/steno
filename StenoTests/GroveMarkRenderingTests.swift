import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// The voice quill wherever it is drawn: the bundle's icon set, the icon artwork drawn from the mark
/// definition, the runtime Dock icon, and every SwiftUI place the quill sits, in each of its
/// motions, light and dark. Output goes to `STENO_UI_RENDER_OUTPUT/mark`.
@Suite("The mark's renders", .serialized)
@MainActor
struct GroveMarkRenderingTests {
    static var outputDirectory: URL {
        get throws {
            let root = ProcessInfo.processInfo.environment["STENO_UI_RENDER_OUTPUT"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("StenoUIRendering", isDirectory: true)
            let directory = root.appendingPathComponent("mark", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
    }

    /// `image` drawn at exactly `px` pixels square, choosing its representation as the system
    /// would for that size at 1x.
    static func pixels(of image: NSImage, px: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let rect = NSRect(x: 0, y: 0, width: px, height: px)
        if let best = image.bestRepresentation(for: rect, context: NSGraphicsContext.current, hints: nil) {
            best.draw(in: rect)
        } else {
            image.draw(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func appIcon() throws -> NSImage {
        try #require(NSImage(named: "AppIcon"), "the bundle's icon set")
    }

    @Test("The bundle's icon set as shipped: 1024, 128, 32 and 16 px, the small ones enlarged pixel for pixel")
    func appIconSizes() throws {
        let directory = try Self.outputDirectory
        let icon = try Self.appIcon()
        for px in [1024, 128, 32, 16] {
            let rep = Self.pixels(of: icon, px: px)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("app-icon-\(px).png"))
            if px <= 32 {
                let big = try #require(GroveMenuIconRenderingTests.enlarged(rep, by: 256 / px))
                try big.write(to: directory.appendingPathComponent("app-icon-\(px)-enlarged.png"))
            }
            // The tile is the forest at every size.
            let tile = try #require(rep.colorAt(x: px / 2, y: px - 1 - Int(Double(px) * 0.2))?.usingColorSpace(.sRGB))
            #expect(tile.greenComponent > tile.redComponent && tile.greenComponent > tile.blueComponent, "forest at \(px)")
        }
    }

    @Test("The icon artwork drawn from the mark definition: 1024, 128, 32 and 16 px")
    func artworkSizes() throws {
        let colors = BrandMark.Colors.green
        for px in [1024, 128, 32, 16] {
            let tile = RoundedRectangle(cornerRadius: BrandIconArtwork.cornerRadius(px: CGFloat(px)), style: .continuous)
                .path(in: BrandIconArtwork.tileRect(px: CGFloat(px))).cgPath
            let image = try #require(BrandIconArtwork.image(px: px, colors: colors, tileShape: tile))
            let rep = NSBitmapImageRep(cgImage: image)
            let data = try #require(px <= 32 ? GroveMenuIconRenderingTests.enlarged(rep, by: 256 / px)
                                    : rep.representation(using: .png, properties: [:]))
            try data.write(to: Self.outputDirectory.appendingPathComponent("artwork-\(px).png"))
            guard px >= 128 else { continue }
            // The calamus, just above the nib, is the shaft colour.
            let box = BrandMark.box(inTile: BrandIconArtwork.tileRect(px: CGFloat(px)))
            let k = box.width / 100
            // On the rachis curve (nib 10,94, bend 30,30, tip 92,6) at t = 0.18.
            let t: CGFloat = 0.18, u = 1 - t
            let calamus = CGPoint(x: u * u * 10 + 2 * u * t * 30 + t * t * 92, y: u * u * 94 + 2 * u * t * 30 + t * t * 6)
            let at = CGPoint(x: box.minX + calamus.x * k, y: box.minY + calamus.y * k)
            #expect(BrandMark.shaft(in: box, cut: .full).contains(at))
            let probe = try #require(rep.colorAt(x: Int(at.x), y: Int(at.y))?.usingColorSpace(.sRGB))
            let shaft = NSColor(srgbRed: CGFloat((colors.shaft >> 16) & 0xFF) / 255, green: CGFloat((colors.shaft >> 8) & 0xFF) / 255,
                                blue: CGFloat(colors.shaft & 0xFF) / 255, alpha: 1)
            #expect(abs(probe.redComponent - shaft.redComponent) < 0.06 && abs(probe.blueComponent - shaft.blueComponent) < 0.06,
                    "the shaft at \(px): \(probe)")
        }
    }

    @Test("The Dock icons beside real ones, light and dark: the bundle icon, then the runtime one",
          arguments: [false, true])
    func dock(dark: Bool) throws {
        let runtime = try #require(GroveBrandApplier.appIcon)
        #expect(runtime.size == NSSize(width: 1024, height: 1024))
        let real = ["/System/Library/CoreServices/Finder.app", "/System/Applications/Mail.app", "/System/Applications/Notes.app",
                    "/System/Applications/Messages.app"].map { NSWorkspace.shared.icon(forFile: $0) }
        let icons = [real[0], real[1], try Self.appIcon(), runtime, real[2], real[3]]
        let scale = 2, side = 64, gap = 10, pad = 16
        let width = (icons.count * side + (icons.count - 1) * gap + 2 * pad) * scale
        let height = (side + 2 * pad) * scale
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width / scale, height: height / scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        (dark ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.9, alpha: 1)).setFill()
        NSRect(origin: .zero, size: rep.size).fill()
        for (index, icon) in icons.enumerated() {
            icon.draw(in: NSRect(x: pad + index * (side + gap), y: pad, width: side, height: side))
        }
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: Self.outputDirectory.appendingPathComponent("dock-\(dark ? "dark" : "light").png"))
        #expect(data.count > 10_000)
    }

    /// Feeds the listening quills in `Places` a voice once they are on screen.
    static let voice = GroveHaloSource()

    /// Every place the window draws the quill, on its own ground, at its own size, in each motion
    /// as a still frame. Motion is on here, so the frames are the moving ones; the Reduce Motion row
    /// shows what replaces them.
    private struct Places: View {
        @Environment(\.groveTheme) private var theme

        private func glass<Content: View>(_ side: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(theme.forestGradient)
                content()
            }
            .frame(width: side, height: side)
        }

        private func motions(reduceMotion: Bool) -> some View {
            HStack(spacing: 18) {
                ForEach([BrandMarkView.Motion.still, .listening, .writing, .written], id: \.self) { motion in
                    glass(54) {
                        GroveQuill(motion: motion, colors: .glass(theme), source: motion == .listening ? GroveMarkRenderingTests.voice : nil)
                            .frame(width: 28, height: 28)
                    }
                }
                ZStack {
                    Circle().fill(theme.accentColor).frame(width: 44, height: 44)
                    GroveQuill(motion: .written, colors: .flat(barbs: theme.onAccent.opacity(0.8).nsColor, shaft: theme.onAccent.nsColor))
                        .frame(width: 30, height: 30)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(theme.raisedColor)
                    GroveQuill(motion: .written, colors: .flat(barbs: theme.accent.nsColor, shaft: theme.ink.nsColor))
                        .frame(width: 24, height: 24)
                }
                .frame(width: 54, height: 54)
            }
            .environment(\._accessibilityReduceMotion, reduceMotion)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                motions(reduceMotion: false)
                motions(reduceMotion: true)
                HStack(spacing: 18) {
                    // Today's idle stage disc, onboarding's app tile and its first dictation's quill.
                    ZStack {
                        RoundedRectangle(cornerRadius: 20).fill(theme.forestGradient)
                        Circle().fill(theme.cream.opacity(0.10).color).frame(width: 46, height: 46)
                        GroveQuill(colors: .glass(theme)).frame(width: 30, height: 30)
                    }
                    .frame(width: 78, height: 78)
                    GroveAppIconTile(size: 96)
                    GroveQuill(motion: .written, colors: .flat(barbs: theme.accent.opacity(0.7).nsColor, shaft: theme.accent.nsColor))
                        .frame(width: 40, height: 40)
                    // A large still, to compare with the lab's glyph.
                    glass(110) { GroveQuill(colors: .glass(theme)).frame(width: 96, height: 96) }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.groundColor)
        }
    }

    @Test("Every SwiftUI place the quill sits, in every motion, light, dark and Increase Contrast")
    func places() async throws {
        for variant in [GroveRenderHarness.Variant.light, .dark, .contrast] {
            let data = try await GroveRenderHarness.render(
                Places().groveTheme(accentStyle: .dodger), controller: nil, variant: variant,
                size: CGSize(width: 520, height: 330),
                prepare: { for level: Float in [0.3, 0.7, 0.9, 0.6, 0.8, 0.5, 0.75] { Self.voice.send(level) } })
            let name = "places-\(variant.rawValue)"
            try data.write(to: Self.outputDirectory.appendingPathComponent(name + ".png"))
            #expect(data.count > 4_000, "\(name)")
        }
    }
}
