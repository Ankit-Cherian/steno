#if os(macOS)
import AppKit
import Testing
@testable import StenoKit

@Suite("Grove overlay brand: the palette")
struct GroveOverlayBrandPaletteTests {
    private func hex(_ color: NSColor) -> UInt32 {
        let c = color.usingColorSpace(.sRGB)!
        func byte(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
        return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
    }

    @Test("The island is forest with cream words and mint bars; notices are graphite")
    func palette() {
        #expect(GrovePalette.gradient(.forest) == [0x213A2B, 0x0F2419])
        #expect(GrovePalette.gradient(.graphite) == [0x2A2C2B, 0x1B1C1B])
        #expect(hex(GrovePalette.cream) == 0xEEF6F0 && hex(GrovePalette.subtext) == 0xA9C4B2)
        #expect(hex(GrovePalette.mint) == 0x9FDDB4 && hex(GrovePalette.onCream) == 0x143322)
    }

    @Test("Words on the forest island read: cream at 7:1, the soft tail at 4.5:1, bars at 3:1")
    func contrast() {
        func quill(_ color: NSColor) -> QuillColor { QuillColor(hex: hex(color)) }
        for stop in GrovePalette.forest.map({ QuillColor(hex: $0) }) {
            #expect(quill(GrovePalette.cream).contrastRatio(on: stop) >= 7)
            #expect(quill(GrovePalette.subtext).contrastRatio(on: stop) >= 4.5)
            #expect(quill(GrovePalette.mint).contrastRatio(on: stop) >= 3)
        }
        #expect(quill(GrovePalette.onCream).contrastRatio(on: quill(GrovePalette.cream)) >= 7)
    }
}

@Suite("Grove overlay brand: the presenter", .serialized)
@MainActor
struct GroveOverlayBrandPresenterTests {
    private static let display = OverlayDisplayDescriptor(
        id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 56, width: 1728, height: 1028),
        isBuiltIn: true, safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 1085, width: 771, height: 32),
        auxiliaryTopRight: CGRect(x: 956, y: 1085, width: 772, height: 32)
    )

    private func makePresenter(notch: Bool = false) -> WaveformOverlayPresenter {
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.hostedEvidencePrepareOffscreen()
        presenter.setHostedAccessibilityPreferences(.init(
            reduceMotion: false, reduceTransparency: false, increaseContrast: false, preferredBodyPointSize: 13))
        presenter.hostedEvidenceSetPlacement(notch ? .notch(display: Self.display, notch: Self.display.notch!) : .capsule(display: Self.display))
        presenter.setLiveTranscriptEnabled(false)
        presenter.setStopAction {}
        presenter.onCopyResult = {}
        presenter.onUndoDiscard = {}
        presenter.onOpenSettings = { _ in }
        presenter.appearance = .grove
        return presenter
    }

    @Test("Listening draws the forest shell and mint bars")
    func listening() throws {
        let presenter = makePresenter()
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 12))
        #expect(presenter.hostedEvidenceGroveBars()?.color == GrovePalette.mint)
        let png = try #require(presenter.hostedEvidenceRenderCurrentPNG(backdrop: nil, scale: 2))
        let rep = try #require(NSBitmapImageRep(data: png))
        let layout = presenter.hostedEvidenceGroveLayout()
        let row = layout.rowRect(width: presenter.hostedEvidenceCapsuleSize().width)
        let inside = try #require(rep.colorAt(x: Int((row.minX + 6) * 2), y: Int(row.midY * 2))?.usingColorSpace(.sRGB))
        #expect(inside.greenComponent > inside.redComponent && inside.greenComponent > inside.blueComponent, "forest")
        presenter.hide()
    }

    @Test("The voice quill is drawn in the mark's colours, writing and then written, with cream words")
    func quillResult() throws {
        let presenter = makePresenter()
        presenter.show(state: .listening(handsFree: false, elapsedSeconds: 4))
        presenter.show(state: .transcribing)
        let mark = try #require(presenter.hostedEvidenceGroveMark())
        let green = BrandMark.Colors.green
        #expect(mark.barbColors == [BrandMarkView.color(green.barbLow).cgColor, BrandMarkView.color(green.barbHigh).cgColor])
        #expect(mark.shaftColor == BrandMarkView.color(green.shaft).cgColor)
        #expect(presenter.hostedEvidenceGroveMarkMotion() == .writing)
        presenter.show(state: .result(.copied(.other), showsWords: true))
        #expect(presenter.hostedEvidenceGroveMarkMotion() == .written)
        #expect(presenter.hostedEvidenceGroveLabelColor() == GrovePalette.cream)
        presenter.hide()
    }

    @Test("Hands-free keeps Stop and Discard inside the island, and the last minute counts down", arguments: [true, false])
    func handsFreeControls(notch: Bool) throws {
        var stops = 0
        let presenter = makePresenter(notch: notch)
        presenter.setStopAction { stops += 1 }
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 130))
        #expect(presenter.hostedEvidencePlacement()?.isNotch == notch)
        #expect(presenter.hostedEvidenceStopIsAvailable())
        #expect(presenter.hostedEvidenceCancelIsAvailable())
        let frames = presenter.hostedEvidenceGroveRowFrames()
        let stop = try #require(frames[.stop])
        #expect(frames[.cancel] != nil)
        let size = presenter.hostedEvidenceCapsuleSize()
        #expect(stop.maxX <= size.width && stop.maxY <= size.height, "Stop is inside the island")
        presenter.hostedEvidencePressStop()
        #expect(stops == 1)
        presenter.hide()

        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 3_558))
        presenter.showRecordingLimitWarning(limitSeconds: 3_600)
        #expect(presenter.hostedEvidenceGroveModel()?.primaryStyle == .countdown)
        #expect(presenter.hostedEvidenceGroveLabelText()?.hasPrefix("Stops in") == true)
        presenter.hide()
    }
}
#endif
