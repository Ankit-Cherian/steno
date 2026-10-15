import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Draws the Grove menu panel offscreen, under a menu bar like the reference boards, in light
/// and dark, with Increase Contrast and Reduce Transparency. Output goes to
/// `STENO_UI_RENDER_OUTPUT/menu` when set.
@Suite("Grove menu renders", .serialized)
@MainActor
struct GroveMenuRenderingTests {
    enum Scene: String, CaseIterable {
        case idle
        case hover
        case recording
        case undoDiscard = "undo-discard"
        case earlier
        case microphone
        case transcribing
        case microphoneOff = "microphone-off"
        case empty
    }

    enum Look: String, CaseIterable {
        case light
        case dark
        case lightIncreaseContrast = "light-increase-contrast"
        case darkIncreaseContrast = "dark-increase-contrast"
        case lightReduceTransparency = "light-reduce-transparency"

        var scheme: ColorScheme { rawValue.hasPrefix("dark") ? .dark : .light }
        var increaseContrast: Bool { rawValue.contains("increase-contrast") }
        var reduceTransparency: Bool { rawValue.contains("reduce-transparency") }
    }

    private var outputDirectory: URL { get throws { try Self.outputDirectory() } }

    static func outputDirectory() throws -> URL {
        let root = ProcessInfo.processInfo.environment["STENO_UI_RENDER_OUTPUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("StenoUIRendering", isDirectory: true)
        let directory = root.appendingPathComponent("menu", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static let devices = [
        InputDeviceOption(id: "built-in", name: "MacBook Pro Microphone", isDefault: true),
        InputDeviceOption(id: "usb", name: "USB Condenser", isDefault: false),
    ]

    static func snapshot(for scene: Scene) -> MenuBarSnapshot {
        var snapshot = MenuBarSnapshot(
            entries: Array(WindowSampleData.entries().prefix(4)),
            pasteShortcut: GlobalShortcut(keyCode: 9, modifiers: [.control, .option]),
            canPasteLast: true,
            devices: devices,
            selectedDeviceID: nil
        )
        switch scene {
        case .idle, .hover, .earlier, .microphone: break
        case .recording:
            snapshot.lifecycle = .recordingHandsFree
            snapshot.isRecording = true
            snapshot.recordingStartedAt = Date().addingTimeInterval(-14)
        case .undoDiscard: snapshot.canUndoDiscard = true
        case .transcribing: snapshot.lifecycle = .transcribing
        case .microphoneOff: snapshot.microphoneDenied = true
        case .empty:
            snapshot.entries = []
            snapshot.pasteShortcut = nil
        }
        return snapshot
    }

    @Test("Every panel state renders in every look", arguments: Scene.allCases, Look.allCases)
    func render(scene: Scene, look: Look) async throws {
        // The full set only needs the three looks that differ for the quieter scenes.
        if look.reduceTransparency && scene != .idle { return }
        if look.increaseContrast && ![.idle, .hover, .recording, .earlier].contains(scene) { return }
        let state = GroveMenuState()
        state.reset(snapshot: Self.snapshot(for: scene),
                    targetAppName: scene == .recording ? "Mail" : nil, usesKeyboard: false)
        switch scene {
        case .earlier: state.toggle(.earlier)
        case .microphone: state.toggle(.microphone)
        default: break
        }
        if scene == .hover {
            // The pointer over Paste Last Dictation.
            for _ in 0..<3 { state.moveHighlight(by: 1) }
        }
        let data = try await Self.render(state: state, look: look, level: scene == .recording ? 0.714 : nil)
        try data.write(to: outputDirectory.appendingPathComponent("\(scene.rawValue)-\(look.rawValue).png"))
        #expect(data.count > 8_000, "\(scene.rawValue)-\(look.rawValue)")
    }

    /// `level` feeds the header's voice bars, as the controller does while recording.
    static func render(state: GroveMenuState, look: Look, level: Float? = nil) async throws -> Data {
        AppFontRegistry.registerIfNeeded()
        let scene = RenderScene(state: state, look: look)
            .environment(\.colorScheme, look.scheme)
            .environment(\._accessibilityReduceMotion, true)
            .environment(\._accessibilityReduceTransparency, look.reduceTransparency)
            .environment(\._colorSchemeContrast, look.increaseContrast ? .increased : .standard)
        let size = CGSize(width: 460, height: 600)
        let hosting = NSHostingView(rootView: scene.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Draw in sRGB so the PNG holds the authored colours and compares with the reference boards.
        window.colorSpace = .sRGB
        window.appearance = NSAppearance(named: look.scheme == .light ? .aqua : .darkAqua)
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        if let level { state.haloSource.send(level) }
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    /// The panel on a desktop under a menu bar, like the reference boards.
    private struct RenderScene: View {
        @ObservedObject var state: GroveMenuState
        let look: Look

        var body: some View {
            let dark = look.scheme == .dark
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: dark ? [Color(red: 0.07, green: 0.09, blue: 0.08), Color(red: 0.13, green: 0.15, blue: 0.14)]
                        : [Color(red: 0.84, green: 0.89, blue: 0.86), Color(red: 0.89, green: 0.92, blue: 0.9)],
                    startPoint: .top, endPoint: .bottom)
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        Spacer()
                        Image(nsImage: MenuBarIcon.image(for: .idle, frame: 2))
                            .renderingMode(.template)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.12)))
                        Text("Mon 10:25").font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 26)
                    .background(dark ? Color.black.opacity(0.5) : Color.white.opacity(0.6))
                    GroveMenuView(state: state)
                        .groveTheme(accentStyle: .dodger)
                        .shadow(color: .black.opacity(0.3), radius: 18, x: 0, y: 8)
                        .padding(.top, 6)
                        .padding(.leading, 110)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(dark ? Color.white : Color.black)
        }
    }
}

/// The Grove status item icons at 1x and 2x on a menu bar strip, with a nearest-neighbour
/// enlargement of each so the pixels can be checked. Output goes to `STENO_UI_RENDER_OUTPUT/menu`.
@Suite("Grove menu bar icon renders", .serialized)
@MainActor
struct GroveMenuIconRenderingTests {
    static let states: [(String, MenuBarIconState, Int)] = [
        ("idle", .idle, 2), ("attention", .attention, 2), ("recording-low", .recording, 0),
        ("recording-high", .recording, 3), ("transcribing", .transcribing, 2),
    ]

    /// Draws `image` as a template would be: black on a light bar or white on a dark one.
    static func bitmap(of image: NSImage, scale: Int, dark: Bool, pad: CGFloat = 6) -> NSBitmapImageRep {
        let width = Int((image.size.width + pad * 2) * CGFloat(scale))
        let height = Int((image.size.height + 4) * CGFloat(scale))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width / scale, height: height / scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.91, alpha: 1)).setFill()
        NSRect(origin: .zero, size: rep.size).fill()
        let ink = dark ? NSColor.white : NSColor.black
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            ink.set()
            rect.fill(using: .sourceIn)
            return true
        }
        tinted.draw(in: NSRect(x: pad, y: 2, width: image.size.width, height: image.size.height))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func enlarged(_ rep: NSBitmapImageRep, by factor: Int) -> Data? {
        let width = rep.pixelsWide * factor, height = rep.pixelsHigh * factor
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .none
        rep.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return out.representation(using: .png, properties: [:])
    }

    @Test("Every Grove icon draws a template image at 1x and 2x", arguments: [false, true])
    func render(dark: Bool) throws {
        let directory = try GroveMenuRenderingTests.outputDirectory()
        for (name, state, frame) in Self.states {
            let image = MenuBarIcon.image(for: state, frame: frame)
            #expect(image.isTemplate, "\(name)")
            for scale in [1, 2] {
                let rep = Self.bitmap(of: image, scale: scale, dark: dark)
                let data = try #require(Self.enlarged(rep, by: 16 / scale))
                try data.write(to: directory.appendingPathComponent("icon-\(name)-\(scale)x-\(dark ? "dark" : "light").png"))
                #expect(data.count > 400, "\(name) \(scale)x")
            }
        }
    }

    /// The inked box of the idle icon drawn black on clear at `scale`, in pixels (y down).
    static func inkedBox(scale: Int) -> CGRect {
        let image = MenuBarIcon.idle
        let width = Int(image.size.width) * scale, height = Int(image.size.height) * scale
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        var box = CGRect.null
        for y in 0..<height {
            for x in 0..<width where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return box
    }

    @Test("The idle icon is the quill's small cut from the mark definition, on whole pixels at 1x and 2x", arguments: [1, 2])
    func drawnFromTheDefinition(scale: Int) {
        let expected = BrandMark.path(in: CGRect(x: 0, y: 0, width: 18, height: 18), cut: .small, pixelScale: CGFloat(scale))
            .boundingBoxOfPath
        let drawn = Self.inkedBox(scale: scale)
        let s = CGFloat(scale)
        let pixels = CGRect(x: expected.minX * s, y: expected.minY * s, width: expected.width * s, height: expected.height * s)
        // The ink lies inside the definition's box; only the nib's point and the curled tip,
        // finer than a pixel, fall below half coverage at its edges.
        #expect(pixels.insetBy(dx: -1, dy: -1).contains(drawn), "drawn \(drawn) against \(pixels) at \(scale)x")
        #expect(drawn.width >= pixels.width * 0.8 && drawn.height >= pixels.height * 0.8, "drawn \(drawn) against \(pixels)")
    }
}
