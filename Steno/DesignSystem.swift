import AppKit
import CoreText
import SwiftUI
import StenoKit

private extension Color {
    init(hex: Int, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}

struct StenoAccentPalette: Sendable {
    let accent: Color
    let accentSoft: Color
    let accentGlow: Color
    let accentInk: Color
}

struct StenoTheme: Sendable {
    let appearance: AppPreferences.Appearance
    let ink0: Color
    let ink1: Color
    let ink2: Color
    let ink3: Color
    let ink4: Color
    let line: Color
    let lineStrong: Color
    let text: Color
    let textDim: Color
    let textMuted: Color
    let accentPalette: StenoAccentPalette
    let amber: Color
    let amberSoft: Color
    let green: Color
    let greenSoft: Color
    let danger: Color

    var isLight: Bool {
        appearance.mode == .light
    }

    var accent: Color { accentPalette.accent }
    var accentSoft: Color { accentPalette.accentSoft }
    var accentGlow: Color { accentPalette.accentGlow }
    var accentInk: Color { accentPalette.accentInk }
    var selectedAccentFill: Color { accent.opacity(isLight ? 0.10 : 0.14) }
    var selectedAccentBorder: Color { accent.opacity(0.30) }
    var strongSelectedAccentBorder: Color { accent.opacity(0.40) }
    var chromeButtonFill: Color { Color.white.opacity(isLight ? 0.72 : 0.03) }
    var chromeAccentWash: Color { accent.opacity(isLight ? 0.08 : 0.14) }
    var heroSurfaceStart: Color { Color(hex: 0x1B2233) }
    var heroSurfaceEnd: Color { Color(hex: 0x0A0E17) }
    var heroOrbSurfaceStart: Color { Color(hex: 0x121824) }
    var heroOrbSurfaceEnd: Color { Color(hex: 0x080B12) }
    var heroText: Color { Color(hex: 0xEEF2F8) }
    var heroSubtext: Color { Color(hex: 0xEEF2F8, opacity: 0.55) }
    var heroOutline: Color { Color.white.opacity(0.12) }
    var heroIdleFill: Color { Color.white.opacity(0.06) }

    var stageGradient: LinearGradient {
        LinearGradient(
            colors: isLight
                ? [Color(hex: 0xDCE5F0), Color(hex: 0xC7D1E0), Color(hex: 0xB5C1D2)]
                : [Color(hex: 0x1B2437), Color(hex: 0x0A0D14), Color(hex: 0x05070B)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var stageGlowLeading: Color {
        isLight ? Color(hex: 0xC7D3F0, opacity: 0.68) : Color(hex: 0x3A3A8E, opacity: 0.40)
    }

    var stageGlowTrailing: Color {
        isLight ? Color(hex: 0x7CD8FF, opacity: 0.56) : Color(hex: 0x00B4D8, opacity: 0.28)
    }

    var titleBarGradient: LinearGradient {
        LinearGradient(colors: [ink1, ink1], startPoint: .top, endPoint: .bottom)
    }

    var shellGradient: LinearGradient {
        LinearGradient(
            colors: [ink1, ink1.opacity(0.94)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var panelGradient: LinearGradient {
        LinearGradient(
            colors: [ink3, ink3],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var cardGradient: LinearGradient {
        LinearGradient(
            colors: [ink2, ink2],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var spotlightOpacity: Double {
        Double(appearance.atmosphereIntensity) / 100.0
    }
}

@MainActor
enum AppFontRegistry {
    private static var didRegister = false

    static func registerIfNeeded() {
        guard !didRegister, let resourceURL = Bundle.main.resourceURL else {
            return
        }

        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: resourceURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "ttf" else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }

        didRegister = true
    }
}

@MainActor
enum StenoDesign {
    private static let fallbackAppearance = AppPreferences.Appearance()

    #if DEBUG
    static var reviewDirectionOverride: StenoDesignDirection?
    #endif

    static var direction: StenoDesignDirection {
        #if DEBUG
        if let reviewDirectionOverride { return reviewDirectionOverride }
        if let value = Bundle.main.object(forInfoDictionaryKey: "StenoDesignDirection") as? String,
           let direction = StenoDesignDirection(rawValue: value) { return direction }
        #endif
        return .signal
    }

    static var cardCornerRadius: CGFloat { direction == .signal ? 10 : direction == .manuscript ? 2 : 20 }

    static var navigationWidth: CGFloat {
        switch direction {
        case .signal: return 104
        case .manuscript: return 172
        case .current: return 190
        }
    }

    private static var canvas: Color {
        switch direction {
        case .signal: return dynamicColor(light: Color(hex: 0xF1F3EE), dark: Color(hex: 0x181D20))
        case .manuscript: return dynamicColor(light: Color(hex: 0xF5F0E7), dark: Color(hex: 0x202329))
        case .current: return dynamicColor(light: Color(hex: 0xF0F5F2), dark: Color(hex: 0x16282A))
        }
    }

    private static var rail: Color {
        switch direction {
        case .signal: return dynamicColor(light: Color(hex: 0xE7EBE5), dark: Color(hex: 0x111619))
        case .manuscript: return dynamicColor(light: Color(hex: 0xE8E2D7), dark: Color(hex: 0x171C23))
        case .current: return dynamicColor(light: Color(hex: 0xDEEAE6), dark: Color(hex: 0x112023))
        }
    }

    private static var readingSurface: Color {
        switch direction {
        case .signal: return dynamicColor(light: .white, dark: Color(hex: 0x242C2E))
        case .manuscript: return dynamicColor(light: Color(hex: 0xFFFCF5), dark: Color(hex: 0x292D33))
        case .current: return dynamicColor(light: Color(hex: 0xFAFDFC), dark: Color(hex: 0x223739))
        }
    }

    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48

    static let radiusTiny: CGFloat = 4
    static let radiusSmall: CGFloat = 8
    static let radiusMedium: CGFloat = 12
    static let radiusLarge: CGFloat = 16
    static let radiusXLarge: CGFloat = 20
    static let radiusPill: CGFloat = 999

    static let borderThin: CGFloat = 0.5
    static let borderNormal: CGFloat = 1.0
    static let borderThick: CGFloat = 1.5
    static let borderHeavy: CGFloat = 3.0

    static let iconSM: CGFloat = 12
    static let iconMD: CGFloat = 16
    static let iconLG: CGFloat = 20
    static let iconXL: CGFloat = 26

    static let animationFast: Double = 0.16
    static let animationNormal: Double = 0.28
    static let animationSlow: Double = 0.6
    static let animationGlow: Double = 1.2

    static let titleBarHeight: CGFloat = 52
    static let dividerHeight: CGFloat = 1
    static let micButtonInnerRingSize: CGFloat = 104
    static let micButtonOuterRingSize: CGFloat = 120
    static let micButtonSize: CGFloat = 88
    static let micButtonIconSize: CGFloat = 32
    static let windowMinWidth: CGFloat = 940
    static let windowIdealWidth: CGFloat = 1120
    static let windowMinHeight: CGFloat = 640
    static let windowIdealHeight: CGFloat = 760
    static let pickerWidth: CGFloat = 260
    static let searchBarMaxWidth: CGFloat = 280
    static let insertionListHeight: CGFloat = 120

    static func theme(for appearance: AppPreferences.Appearance) -> StenoTheme {
        StenoTheme(
            appearance: appearance,
            ink0: canvas,
            ink1: rail,
            ink2: readingSurface,
            ink3: rail,
            ink4: Color(nsColor: .quaternaryLabelColor).opacity(0.15),
            line: Color(nsColor: .separatorColor),
            lineStrong: Color(nsColor: .separatorColor),
            text: .primary,
            textDim: .secondary,
            textMuted: .secondary,
            accentPalette: accentPalette(for: appearance.accent),
            amber: dynamicColor(light: Color(hex: 0x855400), dark: Color(hex: 0xE8BE75)),
            amberSoft: dynamicColor(light: Color(hex: 0xFFF2D4), dark: Color(hex: 0x3D321F)),
            green: dynamicColor(light: Color(hex: 0x176849), dark: Color(hex: 0x8BD4AF)),
            greenSoft: dynamicColor(light: Color(hex: 0xE3F3E9), dark: Color(hex: 0x20382D)),
            danger: dynamicColor(light: Color(hex: 0xAD322D), dark: Color(hex: 0xFF9C94))
        )
    }

    static func theme(for preferences: AppPreferences) -> StenoTheme {
        theme(for: preferences.appearance)
    }

    static func pageTitle(size: CGFloat = 38) -> Font {
        switch direction {
        case .signal: return .system(size: size, weight: .bold)
        case .manuscript: return .custom("Fraunces", fixedSize: size).weight(.regular)
        case .current: return .system(size: size, weight: .semibold, design: .rounded)
        }
    }

    static func display(size: CGFloat = 56) -> Font {
        switch direction {
        case .signal: return .system(size: size, weight: .heavy)
        case .manuscript: return .custom("Fraunces", fixedSize: size).weight(.regular)
        case .current: return .system(size: size, weight: .medium, design: .rounded)
        }
    }

    static func reading(size: CGFloat) -> Font {
        direction == .manuscript ? .custom("Fraunces", fixedSize: size).weight(.regular) : .system(size: size)
    }

    static func heading1() -> Font { system(size: 18, weight: .semibold) }
    static func heading2() -> Font { system(size: 16, weight: .semibold) }
    static func heading3() -> Font { system(size: 14, weight: .semibold) }
    static func body() -> Font { system(size: 13.5, weight: .regular) }
    static func bodyEmphasis() -> Font { system(size: 13, weight: .medium) }
    static func callout() -> Font { system(size: 12.5, weight: .regular) }
    static func subheadline() -> Font { system(size: 12, weight: .regular) }
    static func caption() -> Font { system(size: 11.5, weight: .regular) }
    static func captionEmphasis() -> Font { system(size: 11.5, weight: .medium) }
    static func label() -> Font { mono(size: 10, weight: .medium) }
    static func labelEmphasis() -> Font { mono(size: 10, weight: .medium) }

    static func system(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        return .system(size: size, weight: weight, design: .monospaced)
    }

    static func monoItalic(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        return .system(size: size, weight: weight, design: .monospaced).italic()
    }

    static func heroSerif(size: CGFloat) -> Font {
        return Font.custom("Fraunces-Italic", fixedSize: size)
    }

    static func relativeDateText(for date: Date, now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func timeText(for date: Date) -> String {
        DisplayTimeFormatter.string(from: date)
    }

    static func appDisplayName(for bundleID: String) -> String {
        guard !bundleID.isEmpty else { return "Unknown" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    static func whisperModelDisplayName(for modelPath: String) -> String {
        let filename = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
        guard !filename.isEmpty else { return "unknown" }

        return filename
            .replacingOccurrences(of: "ggml-", with: "")
            .replacingOccurrences(of: "model-", with: "")
    }

    static var accent: Color { theme(for: fallbackAppearance).accent }
    static var background: Color { theme(for: fallbackAppearance).ink0 }
    static var surface: Color { theme(for: fallbackAppearance).ink2 }
    static var surfaceSecondary: Color { theme(for: fallbackAppearance).ink3 }
    static var textPrimary: Color { .primary }
    static var textSecondary: Color { .secondary }
    static var border: Color { dynamicColor(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.09)) }
    static var success: Color { theme(for: fallbackAppearance).green }
    static var successBackground: Color { Color(hex: 0x6EBF8C, opacity: 0.15) }
    static var successBorder: Color { Color(hex: 0x6EBF8C, opacity: 0.30) }
    static var warning: Color { theme(for: fallbackAppearance).amber }
    static var warningBackground: Color { Color(hex: 0xE0B771, opacity: 0.15) }
    static var warningBorder: Color { Color(hex: 0xE0B771, opacity: 0.28) }
    static var error: Color { theme(for: fallbackAppearance).danger }
    static var errorBackground: Color { Color(hex: 0xF2716A, opacity: 0.15) }
    static var errorBorder: Color { Color(hex: 0xF2716A, opacity: 0.25) }

    static var opacityDisabled: Double { 0.5 }
    static var opacitySubtle: Double { 0.12 }
    static var opacityMuted: Double { 0.2 }
    static var opacityBorder: Double { 0.3 }
    static var opacityHover: Double { 0.08 }
    static var opacityGlowMax: Double { 0.8 }

    private static func dynamicColor(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        }))
    }

    private static func accentPalette(for style: StenoAccentStyle) -> StenoAccentPalette {
        let light: Int
        let dark: Int
        switch style {
        case .citron: (light, dark) = (0x526500, 0xD4EB6D)
        case .terracotta: (light, dark) = (0xB7492C, 0xEEA080)
        case .dodger: (light, dark) = (0x155DA8, 0x86BFFF)
        case .cyan: (light, dark) = (0x00697C, 0x74DAEB)
        case .violet: (light, dark) = (0x6544AB, 0xC4ADFF)
        case .emerald: (light, dark) = (0x176849, 0x87DAB6)
        case .rose: (light, dark) = (0xA33753, 0xFBA2B7)
        }
        let accent = dynamicColor(light: Color(hex: light), dark: Color(hex: dark))
        return StenoAccentPalette(
            accent: accent,
            accentSoft: accent.opacity(0.12),
            accentGlow: .clear,
            accentInk: dynamicColor(light: .white, dark: Color(hex: 0x152026))
        )
    }

}

struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

extension ShadowStyle {
    static let soft = ShadowStyle(color: .black.opacity(0.22), radius: 14, x: 0, y: 10)
}

struct CardStyle: ViewModifier {
    var padding: CGFloat = StenoDesign.md

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(StenoDesign.surface)
            .clipShape(RoundedRectangle(cornerRadius: StenoDesign.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: StenoDesign.cardCornerRadius)
                    .stroke(StenoDesign.border, lineWidth: StenoDesign.borderThin)
            )

    }
}

struct InteractiveCardStyle: ViewModifier {
    var padding: CGFloat = StenoDesign.md
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(StenoDesign.surface)
            .clipShape(RoundedRectangle(cornerRadius: StenoDesign.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: StenoDesign.cardCornerRadius)
                    .stroke(StenoDesign.border.opacity(isHovering ? 1 : 0.75), lineWidth: StenoDesign.borderThin)
            )
            .shadow(color: .black.opacity(isHovering ? 0.26 : 0.18), radius: isHovering ? 18 : 12, x: 0, y: isHovering ? 12 : 8)
            .scaleEffect(isHovering && !reduceMotion ? 1.004 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: StenoDesign.animationFast), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1.0)
            .animation(
                reduceMotion ? nil : .interactiveSpring(response: 0.18, dampingFraction: 0.8),
                value: configuration.isPressed
            )
    }
}

struct CopyButtonView: View {
    let action: () -> Void
    var label: String = "Copy transcript"
    @State private var didCopy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            action()
            didCopy = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                didCopy = false
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(StenoDesign.caption())
                .foregroundStyle(didCopy ? StenoDesign.success : StenoDesign.textSecondary)
                .scaleEffect(didCopy && !reduceMotion ? 1.12 : 1.0)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.66),
                    value: didCopy
                )
        }
        .buttonStyle(.plain)
        .help("Copy")
        .accessibilityLabel(label)
    }
}

extension View {
    func cardStyle(padding: CGFloat = StenoDesign.md) -> some View {
        modifier(CardStyle(padding: padding))
    }

    func interactiveCardStyle(padding: CGFloat = StenoDesign.md) -> some View {
        modifier(InteractiveCardStyle(padding: padding))
    }
}
