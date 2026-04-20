import AppKit
import SwiftUI

struct StenoStageBackground: View {
    let theme: StenoTheme

    var body: some View {
        ZStack {
            theme.stageGradient

            RadialGradient(
                colors: [theme.stageGlowLeading, .clear],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 520
            )
            .opacity(0.95 * theme.spotlightOpacity)

            RadialGradient(
                colors: [theme.stageGlowTrailing, .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 560
            )
            .opacity(0.9 * theme.spotlightOpacity)

            StenoNoiseOverlay(opacity: 0.08 + (0.14 * theme.spotlightOpacity))
                .blendMode(theme.isLight ? .overlay : .screen)
        }
        .ignoresSafeArea()
    }
}

private struct StenoNoiseOverlay: View {
    let opacity: Double

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
            var generator = SeededGenerator(seed: 42)
            for _ in 0..<380 {
                let x = CGFloat.random(in: 0...size.width, using: &generator)
                let y = CGFloat.random(in: 0...size.height, using: &generator)
                let rect = CGRect(x: x, y: y, width: 1.2, height: 1.2)
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(.white.opacity(opacity))
                )
            }
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = 2862933555777941757 &* state &+ 3037000493
        return state
    }
}

struct StenoWindowSurface: ViewModifier {
    let theme: StenoTheme

    func body(content: Content) -> some View {
        content
            .background(theme.shellGradient)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(theme.lineStrong, lineWidth: StenoDesign.borderThin)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(theme.isLight ? 0.22 : 0.42), radius: 34, x: 0, y: 28)
    }
}

struct StenoBadge: View {
    enum Tone {
        case neutral
        case accent
        case green
        case amber
        case danger
    }

    let text: String
    let tone: Tone
    let theme: StenoTheme
    var icon: String?
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: compact ? 9 : 10, weight: .medium))
            }
            Text(text)
                .font(compact ? StenoDesign.mono(size: 10, weight: .medium) : StenoDesign.captionEmphasis())
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 3 : 4)
        .background(background)
        .overlay(
            Capsule(style: .continuous)
                .stroke(border, lineWidth: StenoDesign.borderThin)
        )
        .clipShape(Capsule(style: .continuous))
    }

    private var foreground: Color {
        switch tone {
        case .neutral:
            return theme.textDim
        case .accent:
            return theme.accent
        case .green:
            return theme.green
        case .amber:
            return theme.amber
        case .danger:
            return theme.danger
        }
    }

    private var background: Color {
        switch tone {
        case .neutral:
            return Color.white.opacity(theme.isLight ? 0.74 : 0.04)
        case .accent:
            return theme.accentSoft
        case .green:
            return theme.greenSoft
        case .amber:
            return theme.amberSoft
        case .danger:
            return theme.danger.opacity(0.15)
        }
    }

    private var border: Color {
        switch tone {
        case .neutral:
            return theme.lineStrong
        case .accent:
            return theme.accent.opacity(0.3)
        case .green:
            return theme.green.opacity(0.35)
        case .amber:
            return theme.amber.opacity(0.35)
        case .danger:
            return theme.danger.opacity(0.35)
        }
    }
}

struct StenoActionButtonStyle: ButtonStyle {
    enum Tone {
        case primary
        case ghost
        case soft
        case danger
    }

    let theme: StenoTheme
    let tone: Tone

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .frame(height: 30)
            .font(StenoDesign.callout().weight(.medium))
            .background(background(isPressed: configuration.isPressed))
            .foregroundStyle(foreground)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(border, lineWidth: StenoDesign.borderThin)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .shadow(
                color: tone == .primary ? theme.accentGlow.opacity(configuration.isPressed ? 0.20 : 0.34) : .clear,
                radius: 12,
                x: 0,
                y: 4
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(
                reduceMotion ? nil : .interactiveSpring(response: 0.18, dampingFraction: 0.82),
                value: configuration.isPressed
            )
    }

    private var foreground: Color {
        switch tone {
        case .primary:
            return theme.accentInk
        case .ghost:
            return theme.text
        case .soft:
            return theme.textDim
        case .danger:
            return theme.danger
        }
    }

    private var border: Color {
        switch tone {
        case .primary:
            return theme.accent.opacity(0.75)
        case .ghost, .soft, .danger:
            return theme.lineStrong
        }
    }

    private func background(isPressed: Bool) -> some ShapeStyle {
        switch tone {
        case .primary:
            return AnyShapeStyle(isPressed ? theme.accent.opacity(0.92) : theme.accent)
        case .ghost:
            return AnyShapeStyle(Color.white.opacity(theme.isLight ? 0.70 : (isPressed ? 0.08 : 0.04)))
        case .soft:
            return AnyShapeStyle(isPressed ? theme.accentSoft : Color.white.opacity(theme.isLight ? 0.62 : 0.03))
        case .danger:
            return AnyShapeStyle(Color.white.opacity(theme.isLight ? 0.65 : 0.03))
        }
    }
}

struct StenoKeyCapsule: View {
    let text: String
    let theme: StenoTheme

    var body: some View {
        Text(text)
            .font(StenoDesign.mono(size: 10, weight: .medium))
            .foregroundStyle(theme.textDim)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(Color.white.opacity(theme.isLight ? 0.78 : 0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(theme.lineStrong, lineWidth: StenoDesign.borderThin)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct StenoSegmentedTabBar: View {
    @Binding var selection: StenoTab
    let theme: StenoTheme

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(StenoTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: symbol(for: tab))
                            .font(.system(size: 11, weight: .medium))
                        Text(tab.rawValue)
                            .font(StenoDesign.callout().weight(.medium))
                    }
                    .foregroundStyle(selection == tab ? theme.text : theme.textDim)
                    .frame(minWidth: 92)
                    .padding(.vertical, 6)
                    .background(
                        ZStack {
                            if selection == tab {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(theme.isLight ? 0.90 : 0.08),
                                                Color.white.opacity(theme.isLight ? 0.82 : 0.03)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .matchedGeometryEffect(id: "tab-thumb", in: namespace)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(theme.lineStrong, lineWidth: StenoDesign.borderThin)
                                    )
                                    .shadow(color: .black.opacity(theme.isLight ? 0.08 : 0.28), radius: 8, x: 0, y: 2)
                            }
                        }
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(theme.isLight ? 0.52 : 0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.lineStrong, lineWidth: StenoDesign.borderThin)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func symbol(for tab: StenoTab) -> String {
        switch tab {
        case .record:
            return "mic"
        case .history:
            return "clock"
        case .settings:
            return "gearshape"
        }
    }
}

struct AppGlyphView: View {
    let bundleID: String
    let appName: String
    var size: CGFloat = 24

    var body: some View {
        if let image = appIcon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(.sRGB, red: 43.0 / 255.0, green: 106.0 / 255.0, blue: 224.0 / 255.0),
                                Color(.sRGB, red: 29.0 / 255.0, green: 29.0 / 255.0, blue: 31.0 / 255.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text(String(appName.prefix(1)))
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
    }

    private var appIcon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
