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
        LinearGradient(
            colors: isLight
                ? [Color(hex: 0xFBFCFE), Color(hex: 0xF2F5FA)]
                : [Color(hex: 0x11161F), Color(hex: 0x0C1017)],
            startPoint: .top,
            endPoint: .bottom
        )
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
            colors: [
                Color.white.opacity(isLight ? 0.78 : 0.035),
                ink3
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var cardGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(isLight ? 0.82 : 0.045),
                ink2
            ],
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

enum StenoDesign {
    private static let fallbackAppearance = AppPreferences.Appearance()

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
    static let windowMinWidth: CGFloat = 1040
    static let windowIdealWidth: CGFloat = 1120
    static let windowMinHeight: CGFloat = 720
    static let windowIdealHeight: CGFloat = 760
    static let pickerWidth: CGFloat = 260
    static let searchBarMaxWidth: CGFloat = 280
    static let insertionListHeight: CGFloat = 120

    static func theme(for appearance: AppPreferences.Appearance) -> StenoTheme {
        let accentPalette = accentPalette(for: appearance.accent)

        if appearance.mode == .light {
            return StenoTheme(
                appearance: appearance,
                ink0: Color(hex: 0xEEF1F6),
                ink1: Color(hex: 0xF5F7FB),
                ink2: Color(hex: 0xFFFFFF),
                ink3: Color(hex: 0xFFFFFF),
                ink4: Color(hex: 0xF0F3F9),
                line: Color(.sRGB, red: 10.0 / 255.0, green: 15.0 / 255.0, blue: 25.0 / 255.0, opacity: 0.07),
                lineStrong: Color(.sRGB, red: 10.0 / 255.0, green: 15.0 / 255.0, blue: 25.0 / 255.0, opacity: 0.12),
                text: Color(hex: 0x0E1420),
                textDim: Color(hex: 0x4A5568),
                textMuted: Color(hex: 0x6B7384),
                accentPalette: accentPalette,
                amber: Color(hex: 0xE0B771),
                amberSoft: Color(hex: 0xE0B771, opacity: 0.20),
                green: Color(hex: 0x6EBF8C),
                greenSoft: Color(hex: 0x6EBF8C, opacity: 0.15),
                danger: Color(hex: 0xF2716A)
            )
        }

        return StenoTheme(
            appearance: appearance,
            ink0: Color(hex: 0x07090D),
            ink1: Color(hex: 0x0B0E14),
            ink2: Color(hex: 0x11151D),
            ink3: Color(hex: 0x171C26),
            ink4: Color(hex: 0x1F2532),
            line: Color.white.opacity(0.07),
            lineStrong: Color.white.opacity(0.11),
            text: Color(hex: 0xE8ECF2),
            textDim: Color(hex: 0x9AA3B2),
            textMuted: Color(hex: 0x6B7384),
            accentPalette: accentPalette,
            amber: Color(hex: 0xE0B771),
            amberSoft: Color(hex: 0xE0B771, opacity: 0.15),
            green: Color(hex: 0x6EBF8C),
            greenSoft: Color(hex: 0x6EBF8C, opacity: 0.15),
            danger: Color(hex: 0xF2716A)
        )
    }

    static func theme(for preferences: AppPreferences) -> StenoTheme {
        theme(for: preferences.appearance)
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
        return Font.custom("JetBrains Mono", fixedSize: size).weight(weight)
    }

    static func monoItalic(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        return Font.custom("JetBrainsMonoItalic-Regular", fixedSize: size).weight(weight)
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
    static var background: Color { dynamicColor(light: Color(hex: 0xF5F7FB), dark: Color(hex: 0x0B0E14)) }
    static var surface: Color { dynamicColor(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x11151D)) }
    static var surfaceSecondary: Color { dynamicColor(light: Color(hex: 0xF0F3F9), dark: Color(hex: 0x171C26)) }
    static var textPrimary: Color { dynamicColor(light: Color(hex: 0x0E1420), dark: Color(hex: 0xE8ECF2)) }
    static var textSecondary: Color { dynamicColor(light: Color(hex: 0x4A5568), dark: Color(hex: 0x9AA3B2)) }
    static var border: Color { dynamicColor(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.09)) }
    static var success: Color { Color(hex: 0x6EBF8C) }
    static var successBackground: Color { Color(hex: 0x6EBF8C, opacity: 0.15) }
    static var successBorder: Color { Color(hex: 0x6EBF8C, opacity: 0.30) }
    static var warning: Color { Color(hex: 0xE0B771) }
    static var warningBackground: Color { Color(hex: 0xE0B771, opacity: 0.15) }
    static var warningBorder: Color { Color(hex: 0xE0B771, opacity: 0.28) }
    static var error: Color { Color(hex: 0xF2716A) }
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
        switch style {
        case .dodger:
            return StenoAccentPalette(
                accent: Color(hex: 0x1E90FF),
                accentSoft: Color(hex: 0x1E90FF, opacity: 0.18),
                accentGlow: Color(hex: 0x1E90FF, opacity: 0.45),
                accentInk: Color(hex: 0x0A2540)
            )
        case .cyan:
            return StenoAccentPalette(
                accent: Color(hex: 0x12CBF5),
                accentSoft: Color(hex: 0x12CBF5, opacity: 0.18),
                accentGlow: Color(hex: 0x12CBF5, opacity: 0.35),
                accentInk: Color(hex: 0x0C4C5B)
            )
        case .violet:
            return StenoAccentPalette(
                accent: Color(hex: 0xA58DFF),
                accentSoft: Color(hex: 0xA58DFF, opacity: 0.20),
                accentGlow: Color(hex: 0xA58DFF, opacity: 0.40),
                accentInk: Color(hex: 0x332857)
            )
        case .emerald:
            return StenoAccentPalette(
                accent: Color(hex: 0x3CC998),
                accentSoft: Color(hex: 0x3CC998, opacity: 0.18),
                accentGlow: Color(hex: 0x3CC998, opacity: 0.35),
                accentInk: Color(hex: 0x114639)
            )
        case .rose:
            return StenoAccentPalette(
                accent: Color(hex: 0xF87584),
                accentSoft: Color(hex: 0xF87584, opacity: 0.20),
                accentGlow: Color(hex: 0xF87584, opacity: 0.40),
                accentInk: Color(hex: 0x5C1E2D)
            )
        }
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
            .clipShape(RoundedRectangle(cornerRadius: StenoDesign.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: StenoDesign.radiusMedium)
                    .stroke(StenoDesign.border, lineWidth: StenoDesign.borderThin)
            )
            .shadow(color: ShadowStyle.soft.color, radius: ShadowStyle.soft.radius, x: ShadowStyle.soft.x, y: ShadowStyle.soft.y)
    }
}

struct InteractiveCardStyle: ViewModifier {
    var padding: CGFloat = StenoDesign.md
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(StenoDesign.surface)
            .clipShape(RoundedRectangle(cornerRadius: StenoDesign.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: StenoDesign.radiusMedium)
                    .stroke(StenoDesign.border.opacity(isHovering ? 1 : 0.75), lineWidth: StenoDesign.borderThin)
            )
            .shadow(color: .black.opacity(isHovering ? 0.26 : 0.18), radius: isHovering ? 18 : 12, x: 0, y: isHovering ? 12 : 8)
            .scaleEffect(isHovering ? 1.004 : 1)
            .animation(.easeInOut(duration: StenoDesign.animationFast), value: isHovering)
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
