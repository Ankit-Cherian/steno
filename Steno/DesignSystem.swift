import AppKit
import SwiftUI

enum StenoDesign {
    // MARK: - Colors

    private static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark) : NSColor(light)
        }))
    }

    static let accent = Color(red: 0.118, green: 0.565, blue: 1.0) // #1E90FF
    static let background = adaptive(
        light: Color(red: 0.98, green: 0.98, blue: 0.98),       // #FAFAFA
        dark: Color(red: 0.11, green: 0.11, blue: 0.12)          // #1C1C1E
    )
    static let surface = adaptive(
        light: .white,
        dark: Color(red: 0.17, green: 0.17, blue: 0.18)          // #2C2C2E
    )
    static let surfaceSecondary = adaptive(
        light: Color(red: 0.961, green: 0.961, blue: 0.961),     // #F5F5F5
        dark: Color(red: 0.227, green: 0.227, blue: 0.235)       // #3A3A3C
    )
    static let textPrimary = adaptive(
        light: Color(red: 0.102, green: 0.102, blue: 0.102),     // #1A1A1A
        dark: Color(red: 0.922, green: 0.922, blue: 0.922)       // #EBEBEB
    )
    static let textSecondary = adaptive(
        light: Color(red: 0.557, green: 0.557, blue: 0.576),     // #8E8E93
        dark: Color(red: 0.596, green: 0.596, blue: 0.616)       // #98989D
    )
    static let border = adaptive(
        light: Color(red: 0.898, green: 0.898, blue: 0.918),     // #E5E5EA
        dark: Color(red: 0.282, green: 0.282, blue: 0.290)       // #48484A
    )

    // Semantic colors (Apple HIG)
    static let success = Color(red: 0.20, green: 0.78, blue: 0.35) // #34C759
    static let successBackground = success.opacity(0.15)
    static let successBorder = success.opacity(0.3)
    static let warning = Color(red: 1.0, green: 0.58, blue: 0.0) // #FF9500
    static let warningBackground = warning.opacity(0.15)
    static let warningBorder = warning.opacity(0.3)
    static let error = Color(red: 1.0, green: 0.23, blue: 0.19) // #FF3B30
    static let errorBackground = error.opacity(0.15)
    static let errorBorder = error.opacity(0.2)

    // MARK: - Typography

    static func heading1() -> Font { .title3.weight(.bold) }
    static func heading2() -> Font { .title3.weight(.semibold) }
    static func heading3() -> Font { .headline }
    static func body() -> Font { .body }
    static func bodyEmphasis() -> Font { .subheadline.weight(.semibold) }
    static func callout() -> Font { .callout }
    static func subheadline() -> Font { .subheadline }
    static func caption() -> Font { .caption }
    static func captionEmphasis() -> Font { .caption.weight(.medium) }
    static func label() -> Font { .caption2.weight(.medium) }
    static func labelEmphasis() -> Font { .caption2.weight(.semibold) }

    // MARK: - Opacity

    static let opacityDisabled: Double = 0.5
    static let opacitySubtle: Double = 0.12
    static let opacityMuted: Double = 0.2
    static let opacityBorder: Double = 0.3
    static let opacityHover: Double = 0.08
    static let opacityGlowMax: Double = 0.8

    // MARK: - Spacing

    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48

    // MARK: - Radii

    static let radiusTiny: CGFloat = 2
    static let radiusSmall: CGFloat = 8
    static let radiusMedium: CGFloat = 12
    static let radiusLarge: CGFloat = 16
    static let radiusPill: CGFloat = 999

    // MARK: - Border Widths

    static let borderThin: CGFloat = 0.5
    static let borderNormal: CGFloat = 1.0
    static let borderThick: CGFloat = 2.0
    static let borderHeavy: CGFloat = 3.0

    // MARK: - Icon Sizes

    static let iconSM: CGFloat = 12
    static let iconMD: CGFloat = 16
    static let iconLG: CGFloat = 20
    static let iconXL: CGFloat = 26

    // MARK: - Animation Durations

    static let animationFast: Double = 0.15
    static let animationNormal: Double = 0.3
    static let animationSlow: Double = 0.5
    static let animationGlow: Double = 1.2

    // MARK: - Shadow System

    enum ShadowLevel {
        case none, sm, md, lg, xl, recording, idle

        var style: ShadowStyle {
            switch self {
            case .none:
                return ShadowStyle(color: .clear, radius: 0, x: 0, y: 0)
            case .sm:
                return ShadowStyle(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
            case .md:
                return ShadowStyle(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
            case .lg:
                return ShadowStyle(color: .black.opacity(0.10), radius: 8, x: 0, y: 4)
            case .xl:
                return ShadowStyle(color: .black.opacity(0.15), radius: 12, x: 0, y: 6)
            case .recording:
                return ShadowStyle(color: StenoDesign.accent.opacity(0.3), radius: 12, x: 0, y: 2)
            case .idle:
                return ShadowStyle(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
            }
        }

        var darkStyle: ShadowStyle {
            switch self {
            case .none:
                return ShadowStyle(color: .clear, radius: 0, x: 0, y: 0)
            case .sm:
                return ShadowStyle(color: .black.opacity(0.20), radius: 2, x: 0, y: 1)
            case .md:
                return ShadowStyle(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
            case .lg:
                return ShadowStyle(color: .black.opacity(0.30), radius: 8, x: 0, y: 4)
            case .xl:
                return ShadowStyle(color: .black.opacity(0.40), radius: 12, x: 0, y: 6)
            case .recording:
                return ShadowStyle(color: StenoDesign.accent.opacity(0.3), radius: 12, x: 0, y: 2)
            case .idle:
                return ShadowStyle(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
            }
        }
    }

    // MARK: - Component Sizes

    static let micButtonGlowSize: CGFloat = 88
    static let micButtonSize: CGFloat = 72
    static let micButtonGlowScale: CGFloat = 1.2
    static let dividerHeight: CGFloat = 1
    static let windowMinWidth: CGFloat = 600
    static let windowIdealWidth: CGFloat = 620
    static let windowMinHeight: CGFloat = 640
    static let windowIdealHeight: CGFloat = 680
    static let pickerWidth: CGFloat = 260
    static let searchBarMaxWidth: CGFloat = 220
    static let insertionListHeight: CGFloat = 120
}

struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

// MARK: - Shadow Modifier

struct ShadowModifier: ViewModifier {
    let level: StenoDesign.ShadowLevel
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let s = colorScheme == .dark ? level.darkStyle : level.style
        content.shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
    }
}

// MARK: - Card Style

struct CardStyle: ViewModifier {
    var elevation: StenoDesign.ShadowLevel = .md
    var padding: CGFloat = StenoDesign.md

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(StenoDesign.surface)
            .clipShape(RoundedRectangle(cornerRadius: StenoDesign.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: StenoDesign.radiusMedium)
                    .stroke(StenoDesign.border, lineWidth: StenoDesign.borderNormal)
            )
            .shadowStyle(elevation)
    }
}

// MARK: - Interactive Card Style

struct InteractiveCardStyle: ViewModifier {
    var elevation: StenoDesign.ShadowLevel = .md
    var padding: CGFloat = StenoDesign.md

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(StenoDesign.surface)
            .clipShape(RoundedRectangle(cornerRadius: StenoDesign.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: StenoDesign.radiusMedium)
                    .stroke(StenoDesign.border, lineWidth: StenoDesign.borderNormal)
            )
            .shadowStyle(isHovering ? .lg : elevation)
            .scaleEffect(isHovering ? 1.005 : 1.0)
            .animation(.easeInOut(duration: StenoDesign.animationFast), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

// MARK: - Pressable Button Style

struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1.0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.1, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}

// MARK: - Copy Button View

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
                .scaleEffect(didCopy && !reduceMotion ? 1.15 : 1.0)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.6),
                    value: didCopy
                )
        }
        .buttonStyle(.plain)
        .help("Copy")
        .accessibilityLabel(label)
    }
}

// MARK: - View Extensions

extension View {
    func shadowStyle(_ level: StenoDesign.ShadowLevel) -> some View {
        modifier(ShadowModifier(level: level))
    }

    func cardStyle(elevation: StenoDesign.ShadowLevel = .md, padding: CGFloat = StenoDesign.md) -> some View {
        modifier(CardStyle(elevation: elevation, padding: padding))
    }

    func interactiveCardStyle(elevation: StenoDesign.ShadowLevel = .md, padding: CGFloat = StenoDesign.md) -> some View {
        modifier(InteractiveCardStyle(elevation: elevation, padding: padding))
    }
}
