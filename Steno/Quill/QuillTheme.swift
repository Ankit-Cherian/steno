import AppKit
import StenoKit
import SwiftUI

/// The colour roles of the Steno 1.1 design for one scheme, accent and contrast setting.
struct QuillPalette: Sendable, Equatable {
    /// Window background.
    var ground: QuillColor
    /// The page.
    var paper: QuillColor
    /// Fields and tracks.
    var well: QuillColor
    /// Primary text.
    var ink: QuillColor
    /// Secondary text and bars.
    var ink2: QuillColor
    /// Margin and captions.
    var ink3: QuillColor
    /// Line numbers.
    var numbers: QuillColor
    /// Hairlines between rows and around groups.
    var rule: QuillColor
    /// Borders of buttons, fields and keycaps.
    var controlBorder: QuillColor
    /// The saved accent: primary buttons, selection, links.
    var accent: QuillColor
    /// Text and icons on an accent fill.
    var onAccent: QuillColor
    /// A faint accent tint for focus halos and hover.
    var accentWash: QuillColor
    /// The double rule beside line numbers.
    var margin: QuillColor
    /// Reserved for Steno at work: overlay, recording plate, What happened.
    var working: QuillColor
    /// Status only: done.
    var ok: QuillColor
    /// Status only: needs attention.
    var caution: QuillColor
    /// Insights chart.
    var chart: QuillColor
    /// Off track of switches.
    var track: QuillColor
}

/// Resolved Steno 1.1 design tokens. Read it with `@Environment(\.quillTheme)` and install it
/// with `.quillTheme(accent:)` near the root of a window.
struct QuillTheme: Sendable, Equatable {
    let accentStyle: StenoAccentStyle
    let scheme: ColorScheme
    let increaseContrast: Bool
    let palette: QuillPalette

    /// Default for views outside a themed hierarchy: cobalt, light, standard contrast.
    static let standard = QuillTheme.resolve(accent: .dodger, scheme: .light, increaseContrast: false)

    static func resolve(accent: StenoAccentStyle, scheme: ColorScheme, increaseContrast: Bool) -> QuillTheme {
        QuillTheme(
            accentStyle: accent,
            scheme: scheme,
            increaseContrast: increaseContrast,
            palette: palette(accent: accent, scheme: scheme, increaseContrast: increaseContrast)
        )
    }

    /// The re-tuned accent values for 1.1, light and dark. Accent IDs are unchanged from 1.0.
    static func accentColor(_ accent: StenoAccentStyle, scheme: ColorScheme) -> QuillColor {
        let (light, dark): (UInt32, UInt32) = switch accent {
        case .citron: (0x4A6B10, 0xC9E27A)
        case .terracotta: (0xB0482E, 0xEFA686)
        case .dodger: (0x2A4FD0, 0x8EC0F5)
        case .cyan: (0x0B6A84, 0x7FD3E8)
        case .violet: (0x5A46C4, 0xB9AAFF)
        case .emerald: (0x1D6B55, 0x8FD1AD)
        case .rose: (0xA3365A, 0xF5A3BC)
        }
        return QuillColor(hex: scheme == .dark ? dark : light)
    }

    private static func palette(accent: StenoAccentStyle, scheme: ColorScheme, increaseContrast: Bool) -> QuillPalette {
        let accentColor = accentColor(accent, scheme: scheme)
        if scheme == .dark {
            let inkTint = QuillColor(hex: 0xCDDAFF)
            let ink2 = QuillColor(hex: 0xB8C2DC)
            return QuillPalette(
                ground: QuillColor(hex: 0x070A14),
                paper: QuillColor(hex: 0x0E1220),
                well: QuillColor(hex: 0x0B0F1C),
                ink: QuillColor(hex: 0xEDF2FF),
                ink2: ink2,
                ink3: increaseContrast ? ink2 : QuillColor(hex: 0x97A2C1),
                numbers: increaseContrast ? ink2 : QuillColor(hex: 0x7D89AD),
                rule: inkTint.opacity(increaseContrast ? 0.28 : 0.12),
                controlBorder: inkTint.opacity(increaseContrast ? 0.66 : 0.42),
                accent: accentColor,
                onAccent: QuillColor(hex: 0x0D1330),
                accentWash: accentColor.opacity(0.12),
                margin: accentColor.opacity(increaseContrast ? 0.6 : 0.32),
                working: QuillColor(hex: 0x1B2A7A),
                ok: QuillColor(hex: 0x8FD1AD),
                caution: QuillColor(hex: 0xF0B37A),
                chart: QuillColor(hex: 0x8EC0F5),
                track: QuillColor(hex: 0x6A7394)
            )
        }
        let ink = QuillColor(hex: 0x0E1433)
        let ink2 = QuillColor(hex: 0x3D4560)
        return QuillPalette(
            ground: QuillColor(hex: 0xF4F6FB),
            paper: QuillColor(hex: 0xFFFFFF),
            well: QuillColor(hex: 0xEAF0F8),
            ink: ink,
            ink2: ink2,
            ink3: increaseContrast ? ink2 : QuillColor(hex: 0x535C79),
            numbers: increaseContrast ? ink2 : QuillColor(hex: 0x646D8A),
            rule: ink.opacity(increaseContrast ? 0.24 : 0.11),
            controlBorder: ink.opacity(increaseContrast ? 0.72 : 0.48),
            accent: accentColor,
            onAccent: .white,
            accentWash: accentColor.opacity(0.08),
            margin: accentColor.opacity(increaseContrast ? 0.6 : 0.34),
            working: QuillColor(hex: 0x142C8C),
            ok: QuillColor(hex: 0x2D6A4F),
            caution: QuillColor(hex: 0x94450F),
            chart: QuillColor(hex: 0x2A4FD0),
            track: QuillColor(hex: 0x7D8398)
        )
    }

    var ground: Color { palette.ground.color }
    var paper: Color { palette.paper.color }
    var well: Color { palette.well.color }
    var ink: Color { palette.ink.color }
    var ink2: Color { palette.ink2.color }
    var ink3: Color { palette.ink3.color }
    var numbers: Color { palette.numbers.color }
    var rule: Color { palette.rule.color }
    var controlBorder: Color { palette.controlBorder.color }
    var accent: Color { palette.accent.color }
    var onAccent: Color { palette.onAccent.color }
    var accentWash: Color { palette.accentWash.color }
    var margin: Color { palette.margin.color }
    var working: Color { palette.working.color }
    var ok: Color { palette.ok.color }
    var caution: Color { palette.caution.color }
    var chart: Color { palette.chart.color }
    var track: Color { palette.track.color }
}

extension QuillColor {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension EnvironmentValues {
    @Entry var quillTheme: QuillTheme = .standard
}

/// Resolves the theme from the saved accent and the effective scheme and contrast.
private struct QuillThemeResolver: ViewModifier {
    let accent: StenoAccentStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.environment(
            \.quillTheme,
            QuillTheme.resolve(accent: accent, scheme: colorScheme, increaseContrast: contrast == .increased)
        )
    }
}

extension View {
    /// Installs Steno 1.1 tokens for the saved accent, following the effective colour scheme
    /// and Increase Contrast.
    func quillTheme(accent: StenoAccentStyle) -> some View {
        modifier(QuillThemeResolver(accent: accent))
    }
}
