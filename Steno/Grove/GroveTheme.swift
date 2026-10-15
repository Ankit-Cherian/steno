import StenoKit
import SwiftUI

/// The Grove palette for one scheme and contrast setting.
///
/// Grove uses its own accent while the prototype is on: forest green. The saved accent
/// preference is left alone on disk and is not read here.
struct GroveTheme: Sendable, Equatable {
    let scheme: ColorScheme
    let increaseContrast: Bool

    // Working surfaces
    let ground: QuillColor
    let surface: QuillColor
    let raised: QuillColor
    let well: QuillColor
    let selection: QuillColor
    // Text
    let ink: QuillColor
    let ink2: QuillColor
    let ink3: QuillColor
    // Colour roles
    let accent: QuillColor
    let onAccent: QuillColor
    let ok: QuillColor
    let caution: QuillColor
    let error: QuillColor
    /// Outline of a raised card.
    let ring: QuillColor

    // Forest glass and what sits on it
    let forestTop: QuillColor
    let forestMid: QuillColor
    let forestBottom: QuillColor
    let cream = QuillColor(hex: 0xEEF6F0)
    let subtext: QuillColor
    let mint = QuillColor(hex: 0x9FDDB4)
    let warning = QuillColor(hex: 0xF0C77E)
    /// Text on a cream button on forest glass.
    let onCream = QuillColor(hex: 0x0E2A1C)
    /// The menu bar panel's fill, top to bottom. The panel is forest in both schemes, so these
    /// do not follow the window's light or dark roles.
    let panelTop = QuillColor(hex: 0x24503A)
    let panelMid = QuillColor(hex: 0x173A29)
    let panelBottom = QuillColor(hex: 0x123021)
    /// Text on the menu bar panel's cream Dictate and Stop button.
    let onPanelCream = QuillColor(hex: 0x143322)
    /// The quieter bars of a chart.
    let moss = QuillColor(hex: 0x6E9B7C)
    /// The tint of shadows under raised surfaces: a near-black in the brand's hue.
    let shadowTint = QuillColor(hex: 0x05140C)

    static func resolve(scheme: ColorScheme, increaseContrast: Bool) -> GroveTheme {
        scheme == .dark ? dark(increaseContrast) : light(increaseContrast)
    }

    // Neutral grounds: white in light, near-black in dark. Green is the accent and the colour
    // of live voice (forest glass); it never tints the window.
    private static func light(_ increased: Bool) -> GroveTheme {
        GroveTheme(
            scheme: .light, increaseContrast: increased,
            ground: QuillColor(hex: 0xFFFFFF), surface: QuillColor(hex: 0xFFFFFF), raised: QuillColor(hex: 0xF6F7F6),
            well: QuillColor(hex: 0xF3F4F3), selection: QuillColor(hex: 0xE8EFEB),
            ink: increased ? QuillColor(hex: 0x050606) : QuillColor(hex: 0x1C1E1D),
            ink2: increased ? QuillColor(hex: 0x353937) : QuillColor(hex: 0x5D625F),
            ink3: increased ? QuillColor(hex: 0x4A4F4C) : QuillColor(hex: 0x676C69),
            accent: QuillColor(hex: 0x2A6B49), onAccent: .white, ok: QuillColor(hex: 0x2A6B49),
            caution: increased ? QuillColor(hex: 0x6B4208) : QuillColor(hex: 0x9A5B06),
            error: QuillColor(hex: 0xA8322A),
            ring: increased ? QuillColor(hex: 0x8A8F8C) : QuillColor(hex: 0xE4E6E5),
            forestTop: QuillColor(hex: 0x24513A), forestMid: QuillColor(hex: 0x1B4430), forestBottom: QuillColor(hex: 0x163626),
            subtext: increased ? QuillColor(hex: 0xDCEAE0) : QuillColor(hex: 0xA9C4B2)
        )
    }

    private static func dark(_ increased: Bool) -> GroveTheme {
        GroveTheme(
            scheme: .dark, increaseContrast: increased,
            ground: QuillColor(hex: 0x1A1B1B), surface: QuillColor(hex: 0x1A1B1B), raised: QuillColor(hex: 0x232524),
            well: QuillColor(hex: 0x222423), selection: QuillColor(hex: 0x27352E),
            ink: increased ? QuillColor(hex: 0xFAFBFA) : QuillColor(hex: 0xECEEED),
            ink2: increased ? QuillColor(hex: 0xD3D7D5) : QuillColor(hex: 0xA7ACA9),
            ink3: increased ? QuillColor(hex: 0xB9BDBB) : QuillColor(hex: 0x959B98),
            accent: QuillColor(hex: 0x6DC08F), onAccent: QuillColor(hex: 0x0B1A12), ok: QuillColor(hex: 0x6DC08F),
            caution: QuillColor(hex: 0xE2A549), error: QuillColor(hex: 0xF09A8E),
            ring: increased ? QuillColor(hex: 0x6A6F6C) : QuillColor(hex: 0x2E302F),
            forestTop: QuillColor(hex: 0x24513A), forestMid: QuillColor(hex: 0x1B4430), forestBottom: QuillColor(hex: 0x123021),
            subtext: increased ? QuillColor(hex: 0xDCEAE0) : QuillColor(hex: 0xA9C4B2)
        )
    }

    var isDark: Bool { scheme == .dark }

    // MARK: SwiftUI colours

    var groundColor: Color { ground.color }
    var raisedColor: Color { raised.color }
    var wellColor: Color { well.color }
    var inkColor: Color { ink.color }
    var ink2Color: Color { ink2.color }
    var ink3Color: Color { ink3.color }
    var accentColor: Color { accent.color }
    var onAccentColor: Color { onAccent.color }
    var okColor: Color { ok.color }
    var cautionColor: Color { caution.color }
    var errorColor: Color { error.color }
    var ringColor: Color { ring.color }
    var creamColor: Color { cream.color }
    var subtextColor: Color { subtext.color }
    var mintColor: Color { mint.color }
    var warningColor: Color { warning.color }
    var onCreamColor: Color { onCream.color }
    var onPanelCreamColor: Color { onPanelCream.color }
    var shadowTintColor: Color { shadowTint.color }

    /// The ground behind the pages: white in light, a step below the panels in dark. Panels
    /// read as pages by their edge, not by a grey ground.
    var pageGroundColor: Color { isDark ? QuillColor(hex: 0x141515).color : .white }
    /// A page or panel on that ground.
    var panel: QuillColor { isDark ? QuillColor(hex: 0x1D1F1E) : .white }
    var panelColor: Color { panel.color }
    /// The panel's edge: one soft line around the whole panel, never between rows. With Increase
    /// Contrast it is the panel's only boundary on a ground of the same colour, so it reaches 3:1.
    var panelEdge: QuillColor {
        isDark ? QuillColor(hex: 0xFFFFFF).opacity(increaseContrast ? 0.4 : 0.08)
            : QuillColor(hex: 0x000000).opacity(increaseContrast ? 0.45 : 0.1)
    }
    var panelEdgeColor: Color { panelEdge.color }

    /// Shapes a view as a bordered panel on the page ground.
    func panelBackground(cornerRadius: CGFloat = 14) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(panelColor)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(panelEdgeColor, lineWidth: 1))
    }

    /// The forest glass fill, top to bottom.
    var forestGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: forestTop.color, location: 0),
                .init(color: forestMid.color, location: 0.55),
                .init(color: forestBottom.color, location: 1)
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// The menu bar panel's fill: forest, the same in light and dark.
    var panelGradient: LinearGradient {
        LinearGradient(
            colors: [panelTop.color, panelMid.color, panelBottom.color],
            startPoint: .top, endPoint: .bottom
        )
    }

    // Neutral fills for quiet lists and charts. They are black, white or ink at a low opacity,
    // so they sit on the window ground and on the well alike and never pick up the accent.

    /// The selected row of a list, over the panel.
    var rowSelection: QuillColor {
        isDark ? QuillColor.white.opacity(increaseContrast ? 0.16 : 0.08)
            : QuillColor(hex: 0x000000).opacity(increaseContrast ? 0.12 : 0.06)
    }
    var rowSelectionColor: Color { rowSelection.color }

    /// A row of a list while it is pressed, over the panel.
    var rowPressed: QuillColor { ink.opacity(0.08) }

    /// The search field: ink at 5%.
    var quietFieldColor: Color { ink.opacity(increaseContrast ? 0.1 : 0.05).color }

    /// The caution wash behind a "Not inserted" chip.
    var cautionWash: Color { caution.opacity(isDark ? 0.16 : 0.14).color }

    /// The tokens shared Quill components (buttons, the Fix a word form, status words) read
    /// while they sit inside a Grove window. Hairlines are soft: Grove draws no ruled lines.
    func quillTheme(accentStyle: StenoAccentStyle) -> QuillTheme {
        let palette = QuillPalette(
            ground: ground, paper: raised, well: well,
            ink: ink, ink2: ink2, ink3: ink3, numbers: ink3,
            rule: ring.opacity(increaseContrast ? 0.9 : 0.7),
            controlBorder: ink2.opacity(increaseContrast ? 0.8 : 0.5),
            accent: accent, onAccent: onAccent, accentWash: accent.opacity(0.10),
            margin: accent, working: forestMid, ok: ok, caution: caution,
            chart: accent, track: moss
        )
        return QuillTheme(accentStyle: accentStyle, scheme: scheme, increaseContrast: increaseContrast, palette: palette)
    }
}

extension EnvironmentValues {
    @Entry var groveTheme: GroveTheme = .resolve(scheme: .light, increaseContrast: false)
}

/// Installs the Grove tokens, and the matching Quill tokens for shared components, from the
/// effective colour scheme and Increase Contrast.
private struct GroveThemeResolver: ViewModifier {
    let accentStyle: StenoAccentStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let theme = GroveTheme.resolve(scheme: colorScheme, increaseContrast: contrast == .increased)
        content
            .environment(\.groveTheme, theme)
            .environment(\.quillTheme, theme.quillTheme(accentStyle: accentStyle))
    }
}

extension View {
    /// `accentStyle` is the saved accent. It is carried through unchanged and never shown.
    func groveTheme(accentStyle: StenoAccentStyle) -> some View {
        modifier(GroveThemeResolver(accentStyle: accentStyle))
    }
}
