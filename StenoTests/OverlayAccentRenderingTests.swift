import AppKit
import SwiftUI
import Testing
@testable import Steno
@testable import StenoKit

@Suite("Overlay accent rendering", .serialized)
@MainActor
struct OverlayAccentRenderingTests {
    @Test("Every selected accent reaches waveform, Stop, and rule in both appearances without another text update")
    func everyAccentRendersAndSwitchesImmediately() throws {
        let output = ProcessInfo.processInfo.environment["STENO_OVERLAY_ACCENT_RENDER_OUTPUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("StenoOverlayAccentRenders", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var receipt = ["accent,appearance,expected_accent,width,height,waveform_max_channel_error,stop_max_channel_error,rule_max_channel_error,source_graphemes,visible_graphemes,png_bytes"]
        let styles = StenoAccentStyle.allCases
        for (index, accent) in styles.enumerated() {
            for mode in [StenoAppearanceMode.light, .dark] {
                let initialAccent = styles[(index + 1) % styles.count]
                let initialMode: StenoAppearanceMode = mode == .light ? .dark : .light
                let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
                presenter.hostedEvidencePrepareOffscreen()
                presenter.setStopAction { }
                presenter.setHostedAccessibilityPreferences(.init(
                    reduceMotion: true, reduceTransparency: true, increaseContrast: false,
                    preferredBodyPointSize: 13
                ))
                presenter.updateAppearance(appearance(for: initialMode))
                presenter.updateAccentColor(NSColor(theme(accent: initialAccent, mode: initialMode).accent))
                presenter.show(state: .listening(handsFree: true, elapsedSeconds: 12))
                let session = LiveTranscriptionSession(
                    sessionID: UUID(), controllerGeneration: UUID(), runtimeGeneration: 1, runtimeIdentity: .pending
                )
                let opening = "The selected accent belongs in the recording overlay too."
                let expanded = opening + " Every control should update with the palette while the exact words stay unchanged."
                for (offset, text) in [opening, expanded].enumerated() {
                    presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
                        session: session, stablePrefix: text, revisableTail: "",
                        lastAcceptedRevision: UInt64(offset + 1), decodedAudioWatermark: UInt64(offset + 1) * 1_600
                    ))
                    presenter.hostedEvidenceFlushLiveTranscript()
                }
                let viewportBeforeSwitch = presenter.hostedEvidenceViewport()
                let size = presenter.hostedEvidencePanelSize()
                #expect(size.height > 64)
                #expect(presenter.hostedEvidenceControlsAreNonactivating())
                #expect(presenter.hostedEvidenceUserFacingStrings().contains { $0.hasPrefix("Hands-free ·") })

                // First exercise appearance changes with the retained dynamic
                // color. Then change accent without a resize or text revision.
                presenter.updateAppearance(appearance(for: mode))
                let retained = RGB(resolve(NSColor(theme(accent: initialAccent, mode: mode).accent), mode: mode))
                #expect(RGB(presenter.hostedEvidenceAccentColor()).distance(to: retained) < 0.01)
                let selectedTheme = theme(accent: accent, mode: mode)
                presenter.updateAccentColor(NSColor(selectedTheme.accent), glowColor: NSColor(selectedTheme.accentGlow))
                let selectedColor = resolve(NSColor(selectedTheme.accent), mode: mode)
                let backgroundColor = resolve(NSColor(selectedTheme.ink2), mode: mode)
                let expected = RGB(selectedColor)
                #expect(RGB(presenter.hostedEvidenceAccentColor()).distance(to: expected) < 0.01)
                #expect(presenter.hostedEvidenceViewport() == viewportBeforeSwitch)

                // Re-showing an active listening state does not perform another
                // layout, so stale control tint cannot be hidden by a new frame.
                let data = try #require(presenter.hostedEvidenceRenderPNG(
                    state: .listening(handsFree: true, elapsedSeconds: 12)
                ))
                let bitmap = try #require(NSBitmapImageRep(data: data))
                let name = "overlay-\(accent.rawValue)-\(mode.rawValue)"
                try data.write(to: output.appendingPathComponent(name + ".png"))
                // Core Animation renders and blends in the destination's
                // profile. Convert the reference colors to that same space;
                // a display may clip colors outside its gamut on capture.
                let renderedAccent = RGB(selectedColor, in: bitmap.colorSpace)
                let renderedBackground = RGB(backgroundColor, in: bitmap.colorSpace)
                let waveformError = minimumPixelDistance(in: CGRect(x: 20, y: 14, width: 30, height: 22),
                    expected: renderedAccent, bitmap: bitmap, logicalSize: size)
                let stopError = minimumPixelDistance(in: CGRect(x: size.width - 71, y: 17, width: 14, height: 16),
                    expected: renderedAccent, bitmap: bitmap, logicalSize: size)
                let ruleColor = renderedAccent.composited(over: renderedBackground, alpha: 0.65)
                let ruleError = minimumPixelDistance(in: CGRect(x: 23, y: 40, width: 32, height: 4),
                    expected: ruleColor, bitmap: bitmap, logicalSize: size)
                #expect(waveformError < 0.07, "\(name): waveform did not render the selected accent")
                #expect(stopError < 0.05, "\(name): Stop kept another accent after immediate switching")
                #expect(ruleError < 0.07, "\(name): manuscript rule did not render the selected accent")
                #expect(presenter.hostedEvidenceTextSurfacesAreEmpty())
                receipt.append("\(accent.rawValue),\(mode.rawValue),\(expected.hex),\(size.width),\(size.height),\(waveformError),\(stopError),\(ruleError),\(expanded.count),\(viewportBeforeSwitch.visibleText.count),\(data.count)")
            }
        }
        #expect(receipt.count == 1 + styles.count * 2)
        try (receipt.joined(separator: "\n") + "\n").write(
            to: output.appendingPathComponent("overlay-accent-render-receipt.csv"), atomically: true, encoding: .utf8
        )
    }

    private func theme(accent: StenoAccentStyle, mode: StenoAppearanceMode) -> StenoTheme {
        var appearance = AppPreferences.Appearance()
        appearance.mode = mode
        appearance.accent = accent
        return StenoDesign.theme(for: appearance)
    }

    private func appearance(for mode: StenoAppearanceMode) -> NSAppearance {
        NSAppearance(named: mode == .dark ? .darkAqua : .aqua)!
    }

    private func resolve(_ color: NSColor, mode: StenoAppearanceMode) -> NSColor {
        var resolved = color
        appearance(for: mode).performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        return resolved
    }

    /// Probe each component's own interior. Antialiased boundaries and the
    /// waveform gradient need not match an exact RGB triplet at every pixel.
    private func minimumPixelDistance(in region: CGRect, expected: RGB, bitmap: NSBitmapImageRep,
                                      logicalSize: CGSize) -> Double {
        let scaleX = CGFloat(bitmap.pixelsWide) / logicalSize.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / logicalSize.height
        let x0 = max(0, Int(floor(region.minX * scaleX)))
        let x1 = min(bitmap.pixelsWide, Int(ceil(region.maxX * scaleX)))
        let y0 = max(0, Int(floor(region.minY * scaleY)))
        let y1 = min(bitmap.pixelsHigh, Int(ceil(region.maxY * scaleY)))
        var smallest = Double.infinity
        for y in y0..<y1 {
            for x in x0..<x1 {
                if let color = bitmap.colorAt(x: x, y: y) {
                    // colorAt returns calibrated component values even when
                    // the PNG carries the display's ICC profile. Associate the
                    // raw samples with their actual destination color space.
                    var components = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
                    let profiled = NSColor(colorSpace: bitmap.colorSpace, components: &components, count: 4)
                    smallest = min(smallest, RGB(profiled, in: bitmap.colorSpace).distance(to: expected))
                }
            }
        }
        return smallest
    }

    private struct RGB {
        let r: Double
        let g: Double
        let b: Double

        init(_ color: NSColor, in colorSpace: NSColorSpace = .sRGB) {
            let rgb = color.usingColorSpace(colorSpace) ?? color
            r = rgb.redComponent; g = rgb.greenComponent; b = rgb.blueComponent
        }

        init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

        var hex: String {
            String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }

        func distance(to other: RGB) -> Double {
            max(abs(r - other.r), abs(g - other.g), abs(b - other.b))
        }

        func composited(over background: RGB, alpha: Double) -> RGB {
            .init(r: r * alpha + background.r * (1 - alpha),
                  g: g * alpha + background.g * (1 - alpha),
                  b: b * alpha + background.b * (1 - alpha))
        }
    }
}
