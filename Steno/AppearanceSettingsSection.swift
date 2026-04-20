import SwiftUI

struct AppearanceSettingsSection: View {
    @Binding var appearance: AppPreferences.Appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = StenoDesign.theme(for: appearance)

        VStack(alignment: .leading, spacing: 28) {
            SettingsPrototypeGroup(
                kicker: "THEME",
                title: "Appearance",
                hint: "Match Steno to your mood. Settings here are saved per user.",
                theme: theme
            ) {
                VStack(spacing: 0) {
                    SettingsPrototypeRow(
                        title: "Theme",
                        subtitle: "Dark is designed as the primary experience. Light is equally supported.",
                        theme: theme
                    ) {
                        HStack(spacing: 2) {
                            ForEach(StenoAppearanceMode.allCases, id: \.self) { mode in
                                Button(mode.title) {
                                    appearance.mode = mode
                                }
                                .buttonStyle(ThemeChoiceButtonStyle(
                                    theme: theme,
                                    isSelected: appearance.mode == mode
                                ))
                            }
                        }
                        .padding(2)
                        .background(Color.white.opacity(theme.isLight ? 0.78 : 0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(theme.lineStrong, lineWidth: StenoDesign.borderThin)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }

                    SettingsPrototypeRow(
                        title: "Accent color",
                        subtitle: "Used for active states, focus rings, and the recording pulse.",
                        theme: theme,
                        showsDivider: false
                    ) {
                        HStack(spacing: 8) {
                            ForEach(StenoAccentStyle.allCases) { accent in
                                let accentTheme = StenoDesign.theme(
                                    for: AppPreferences.Appearance(
                                        mode: appearance.mode,
                                        accent: accent,
                                        recordHeroStyle: appearance.recordHeroStyle,
                                        atmosphereIntensity: appearance.atmosphereIntensity
                                    )
                                )

                                Button {
                                    appearance.accent = accent
                                } label: {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(accentTheme.accent)
                                        .frame(width: 26, height: 26)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .stroke(
                                                    appearance.accent == accent ? theme.text : Color.black.opacity(theme.isLight ? 0.12 : 0.24),
                                                    lineWidth: appearance.accent == accent ? 1.5 : 0.5
                                                )
                                        )
                                        .shadow(color: accentTheme.accentGlow, radius: appearance.accent == accent ? 10 : 0)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            SettingsPrototypeGroup(
                kicker: "RECORD SCREEN",
                title: "Hero style",
                hint: "Pick the recording surface you want to see every day.",
                theme: theme
            ) {
                HStack(spacing: 12) {
                    ForEach(StenoRecordHeroStyle.allCases) { hero in
                        Button {
                            appearance.recordHeroStyle = hero
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                AppearanceHeroPreview(
                                    appearance: appearance,
                                    heroStyle: hero,
                                    isActive: appearance.recordHeroStyle == hero,
                                    reduceMotion: reduceMotion
                                )
                                HStack(spacing: 8) {
                                    Text(hero.title)
                                        .font(StenoDesign.bodyEmphasis())
                                        .foregroundStyle(theme.text)
                                    if appearance.recordHeroStyle == hero {
                                        StenoBadge(text: "Active", tone: .accent, theme: theme, compact: true)
                                    }
                                }
                                Text(hero == .pill ? "Horizontal capsule with live waveform panel." : "Circular dial meter with centered capsule.")
                                    .font(StenoDesign.subheadline())
                                    .foregroundStyle(theme.textMuted)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                appearance.recordHeroStyle == hero
                                    ? Color.clear
                                    : Color.white.opacity(theme.isLight ? 0.82 : 0.025)
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(selectedHeroBackground(isSelected: appearance.recordHeroStyle == hero, theme: theme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(
                                        appearance.recordHeroStyle == hero ? theme.strongSelectedAccentBorder : theme.lineStrong,
                                        lineWidth: StenoDesign.borderThin
                                    )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
            }

            SettingsPrototypeGroup(
                kicker: "AMBIENCE",
                title: "Atmosphere",
                hint: "Softens or intensifies the window's depth and spotlight.",
                theme: theme
            ) {
                SettingsPrototypeRow(
                    title: "Intensity · \(appearance.atmosphereIntensity)%",
                    subtitle: "Lower values feel flatter and more utilitarian.",
                    theme: theme,
                    showsDivider: false
                ) {
                    Slider(
                        value: Binding(
                            get: { Double(appearance.atmosphereIntensity) },
                            set: { appearance.atmosphereIntensity = Int($0.rounded()) }
                        ),
                        in: 0...100,
                        step: 1
                    )
                    .tint(theme.accent)
                    .frame(width: 220)
                }
            }
        }
    }

    private func selectedHeroBackground(isSelected: Bool, theme: StenoTheme) -> some ShapeStyle {
        guard isSelected else {
            return AnyShapeStyle(Color.clear)
        }

        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    theme.selectedAccentFill,
                    Color.white.opacity(theme.isLight ? 0.02 : 0.02)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct SettingsPrototypeGroup<Content: View>: View {
    let kicker: String
    let title: String
    let hint: String
    let theme: StenoTheme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(kicker)
                    .font(StenoDesign.mono(size: 10, weight: .medium))
                    .tracking(2.2)
                    .foregroundStyle(theme.textMuted)
                Text(title)
                    .font(StenoDesign.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(hint)
                    .font(StenoDesign.subheadline())
                    .foregroundStyle(theme.textMuted)
            }

            VStack(spacing: 0) {
                content
            }
            .background(theme.cardGradient)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(theme.lineStrong, lineWidth: StenoDesign.borderThin)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(theme.isLight ? 0.12 : 0.26), radius: 18, x: 0, y: 8)
        }
    }
}

private struct SettingsPrototypeRow<Accessory: View>: View {
    let title: String
    let subtitle: String
    let theme: StenoTheme
    var showsDivider = true
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(StenoDesign.bodyEmphasis())
                    .foregroundStyle(theme.text)
                Text(subtitle)
                    .font(StenoDesign.subheadline())
                    .foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            accessory
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(theme.line)
                    .frame(height: 1)
                    .padding(.horizontal, 16)
            }
        }
    }
}

private struct ThemeChoiceButtonStyle: ButtonStyle {
    let theme: StenoTheme
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StenoDesign.callout().weight(.medium))
            .foregroundStyle(isSelected ? theme.text : theme.textMuted)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(isSelected ? Color.white.opacity(theme.isLight ? 0.92 : 0.08) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct AppearanceHeroPreview: View {
    let appearance: AppPreferences.Appearance
    let heroStyle: StenoRecordHeroStyle
    let isActive: Bool
    let reduceMotion: Bool

    private var previewAppearance: AppPreferences.Appearance {
        AppPreferences.Appearance(
            mode: appearance.mode,
            accent: appearance.accent,
            recordHeroStyle: heroStyle,
            atmosphereIntensity: appearance.atmosphereIntensity
        )
    }

    private var theme: StenoTheme {
        StenoDesign.theme(for: previewAppearance)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isActive || reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.heroSurfaceStart, theme.heroSurfaceEnd],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [theme.accentGlow.opacity(0.28), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 54
                        )
                    )
                    .opacity(0.8)

                if heroStyle == .pill {
                    pillPreview(phase: phase)
                } else {
                    ringPreview(phase: phase)
                }
            }
            .frame(height: 72)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.lineStrong, lineWidth: StenoDesign.borderThin)
            )
        }
    }

    private func pillPreview(phase: TimeInterval) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(theme.accent)
                .frame(width: 22, height: 22)
                .shadow(color: theme.accentGlow, radius: 8)

            Canvas { context, size in
                let bars = 9
                let gap: CGFloat = 2
                let width: CGFloat = 2
                let fullWidth = CGFloat(bars) * width + CGFloat(bars - 1) * gap
                let originX = (size.width - fullWidth) / 2

                for index in 0..<bars {
                    let amplitude = isActive ? (0.35 + 0.55 * abs(sin(phase * 2.2 + Double(index) * 0.45))) : 0.25
                    let barHeight = max(6, amplitude * Double(size.height - 10))
                    let rect = CGRect(
                        x: originX + CGFloat(index) * (width + gap),
                        y: (size.height - barHeight) / 2,
                        width: width,
                        height: barHeight
                    )
                    context.fill(
                        RoundedRectangle(cornerRadius: 1.2).path(in: rect),
                        with: .color(theme.accent.opacity(0.75))
                    )
                }
            }
            .frame(width: 54, height: 30)
        }
    }

    private func ringPreview(phase: TimeInterval) -> some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) * 0.32
            let tickCount = 26

            for index in 0..<tickCount {
                let angle = (Double(index) / Double(tickCount)) * .pi * 2
                let isLit = isActive && ((sin(phase * 2 + Double(index) * 0.35) + 1) / 2) > 0.45
                let inner = CGPoint(
                    x: center.x + cos(angle) * (radius - 4),
                    y: center.y + sin(angle) * (radius - 4)
                )
                let outer = CGPoint(
                    x: center.x + cos(angle) * (radius + 3),
                    y: center.y + sin(angle) * (radius + 3)
                )

                var path = Path()
                path.move(to: inner)
                path.addLine(to: outer)
                context.stroke(path, with: .color(isLit ? theme.accent : theme.lineStrong), lineWidth: 1.2)
            }

            context.fill(
                Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)),
                with: .color(theme.accent)
            )
        }
        .frame(width: 64, height: 42)
    }
}
