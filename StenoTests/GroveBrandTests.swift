import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import StenoKit
@testable import Steno

/// Grove has one brand, green, and one look, glass: what the Dock, status item, island and live
/// stage show, and how a choice stored by an earlier build is treated. A stored choice is put in
/// the standard defaults' argument domain, in memory only, as launching with
/// `-stenoGroveIdentity blue` would: the app sees it where it would read it, and nothing is
/// written to any defaults file.
@Suite("Grove brand")
@MainActor
struct GroveBrandTests {
    /// Runs `body` with `values` in the standard defaults' argument domain, then puts the domain
    /// back as it was.
    private func withStoredValues<T>(_ values: [String: String], _ body: () async throws -> T) async throws -> T {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(original.merging(values) { _, new in new }, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for (key, value) in values {
            #expect(defaults.string(forKey: key) == value, "the stored value is where the app would read it")
        }
        return try await body()
    }

    /// The forest tile's colour at a point low in the tile, below the quill.
    private func tileColor(_ image: NSImage) throws -> NSColor {
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh - 1 - rep.pixelsHigh / 5)?.usingColorSpace(.sRGB))
    }

    @Test("A blue identity or the Current design stored by an earlier build shows green Grove")
    func storedBlueReadsAsGreen() async throws {
        try await withStoredValues(["stenoGroveIdentity": "blue", "stenoGroveMark": "quill", "stenoDesignDirection": "quill"]) {
            try showsGreenBrand()
        }
    }

    private func showsGreenBrand() throws {
        // The Dock shows the green tile.
        var icons: [NSImage?] = []
        let applier = GroveBrandApplier(setDockIcon: { icons.append($0) })
        applier.start()
        let dock = try #require(icons.last ?? nil)
        #expect(dock === GroveBrandApplier.appIcon)
        let tile = try tileColor(dock)
        #expect(tile.greenComponent > tile.redComponent && tile.greenComponent > tile.blueComponent, "forest, not cobalt: \(tile)")

        // The window's palette is the forest one.
        for scheme in [ColorScheme.light, .dark] {
            let theme = GroveTheme.resolve(scheme: scheme, increaseContrast: false)
            #expect(theme.accent == QuillColor(hex: scheme == .dark ? 0x6DC08F : 0x2A6B49))
            #expect(theme.forestMid == QuillColor(hex: 0x1B4430) && theme.panelMid == QuillColor(hex: 0x173A29))
            #expect(GroveDayGrid.ramp(for: theme) == (scheme == .dark ? GroveDayGrid.darkRamp : GroveDayGrid.lightRamp))
        }

        // The status item draws the voice quill.
        let menuBar = MenuBarController()
        #expect(menuBar.iconImage(for: .idle, frame: 2) === MenuBarIcon.idle)
    }

    @Test("An island or live stage style stored by an earlier build shows glass",
          arguments: [("paper", "paper"), ("dot", "tint")])
    func storedStylesShowGlass(island: String, stage: String) async throws {
        try await withStoredValues(["stenoGroveIslandStyle": island, "stenoGroveStageStyle": stage]) {
            try await showsGlass()
        }
    }

    private func showsGlass() async throws {
        let applier = GroveBrandApplier(setDockIcon: { _ in })
        applier.start()

        // The island grows out of the notch, as only glass does, and is forest inside.
        let display = GroveOverlayRenderingTests.display
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.hostedEvidencePrepareOffscreen()
        presenter.hostedEvidenceSetPlacement(.notch(display: display, notch: try #require(display.notch)))
        presenter.appearance = .grove
        presenter.updateAppearance(NSAppearance(named: .aqua))
        presenter.setStopAction {}
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 12))
        #expect(presenter.hostedEvidencePlacement()?.isNotch == true)
        let png = try #require(presenter.hostedEvidenceRenderCurrentPNG(backdrop: nil, scale: 2))
        let rep = try #require(NSBitmapImageRep(data: png))
        let row = presenter.hostedEvidenceGroveLayout().rowRect(width: presenter.hostedEvidenceCapsuleSize().width)
        let shell = try #require(rep.colorAt(x: Int((row.minX + 6) * 2), y: Int(row.midY * 2))?.usingColorSpace(.sRGB))
        #expect(shell.greenComponent > shell.redComponent && shell.greenComponent > shell.blueComponent
                && shell.brightnessComponent < 0.4, "a forest island, not white paper: \(shell)")
        presenter.hide()

        // Today's live stage is forest glass in light mode, not a white or pale tinted panel.
        let size = CGSize(width: 560, height: 160)
        let plate = GroveRecordingPlate(mode: .listening(startedAt: Date()), targetApp: "Mail")
            .padding(20)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .groveTheme(accentStyle: .citron)
        let data = try await GroveRenderHarness.render(plate, controller: nil, variant: .light, size: size)
        let stageRep = try #require(NSBitmapImageRep(data: data))
        let pixelsPerPoint = CGFloat(stageRep.pixelsWide) / size.width
        // Inside the plate's left padding, below the quill: only the plate's own fill is there.
        let plateFill = try #require(stageRep.colorAt(x: Int(30 * pixelsPerPoint), y: Int(85 * pixelsPerPoint))?.usingColorSpace(.sRGB))
        #expect(plateFill.greenComponent > plateFill.redComponent && plateFill.greenComponent > plateFill.blueComponent
                && plateFill.brightnessComponent < 0.4, "a forest glass stage, not paper or tint: \(plateFill)")
    }

    @Test("While the app loads, the main window shows Grove's ground, whatever accent 1.0 saved")
    func savedAccentWhileLoading() throws {
        func render(_ accent: StenoAccentStyle) throws -> NSBitmapImageRep {
            let controller = GroveRenderHarness.sampleController(.light, populated: false)
            controller.preferences.appearance.accent = accent
            controller.hasBootstrapped = false
            // ImageRenderer draws one frame and runs no task, so the window stays as it is before loading.
            let renderer = ImageRenderer(content: AppWindowContent(controller: controller, appDelegate: AppDelegate())
                .frame(width: 480, height: 320)
                .environment(\.colorScheme, .light))
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        func pixels(_ rep: NSBitmapImageRep) throws -> Data {
            Data(bytes: try #require(rep.bitmapData), count: rep.bytesPerRow * rep.pixelsHigh)
        }
        let terracotta = try render(.terracotta)
        let emerald = try render(.emerald)
        #expect(try pixels(terracotta) == pixels(emerald), "the saved accent changed the window before loading")
        let ground = try #require(terracotta.colorAt(x: 240, y: 40)?.usingColorSpace(.sRGB))
        let grove = try #require(NSColor(GroveTheme.resolve(scheme: .light, increaseContrast: false).pageGroundColor).usingColorSpace(.sRGB))
        #expect(abs(ground.redComponent - grove.redComponent) < 0.01 && abs(ground.greenComponent - grove.greenComponent) < 0.01
                && abs(ground.blueComponent - grove.blueComponent) < 0.01, "not Grove's ground: \(ground)")
    }

    @Test("The status item draws the voice quill in every state")
    func menuBarIcon() {
        #expect(MenuBarIcon.image(for: .idle, frame: 2) === MenuBarIcon.idle)
        #expect(MenuBarIcon.image(for: .attention, frame: 2) === MenuBarIcon.attention)
        #expect(MenuBarIcon.image(for: .recording, frame: 3) === MenuBarIcon.recordingFrames[3])
        #expect(MenuBarIcon.image(for: .transcribing, frame: 0) === MenuBarIcon.transcribing)
        #expect(MenuBarIcon.idle.size == NSSize(width: 18, height: 18) && MenuBarIcon.attention.size == NSSize(width: 23, height: 18))
        // The recording frames light more of the outer barbs as the level rises.
        let quiet = MenuBarIcon.recordingLengths(level: MenuBarIcon.frameLevels[0])
        let loud = MenuBarIcon.recordingLengths(level: MenuBarIcon.frameLevels[3])
        #expect(zip(quiet, loud).allSatisfy { $0 < $1 })
    }

    @Test("The Dock and the About panel show the green tile")
    func brandApplier() {
        var icons: [NSImage?] = []
        let applier = GroveBrandApplier(setDockIcon: { icons.append($0) })
        applier.start()
        #expect(icons.count == 1 && icons.last! === GroveBrandApplier.appIcon, "the tile drawn from the mark definition")
        #expect(GroveBrandApplier.appIcon?.size == NSSize(width: 1024, height: 1024))
    }
}
