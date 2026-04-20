import SwiftUI
import StenoKit

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case permissions
    case recording
    case engine
    case output
    case cleanup
    case corrections
    case shortcuts
    case media
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance:
            return "Appearance"
        case .permissions:
            return "Permissions"
        case .recording:
            return "Recording"
        case .engine:
            return "Engine"
        case .output:
            return "Text Output"
        case .cleanup:
            return "Cleanup"
        case .corrections:
            return "Word Corrections"
        case .shortcuts:
            return "Text Shortcuts"
        case .media:
            return "Media"
        case .general:
            return "General"
        }
    }

    var symbolName: String {
        switch self {
        case .appearance:
            return "sparkles"
        case .permissions:
            return "checkmark"
        case .recording:
            return "mic"
        case .engine:
            return "cpu"
        case .output:
            return "keyboard"
        case .cleanup:
            return "wand.and.stars"
        case .corrections:
            return "textformat.abc"
        case .shortcuts:
            return "text.badge.plus"
        case .media:
            return "pause.circle"
        case .general:
            return "gearshape"
        }
    }
}

struct SettingsView: View {
    @Binding var selectedSection: SettingsSection
    @EnvironmentObject private var controller: DictationController
    @State private var preferencesDraft: AppPreferences = .default
    @State private var didLoad = false

    init(selectedSection: Binding<SettingsSection> = .constant(.appearance)) {
        _selectedSection = selectedSection
    }

    var body: some View {
        let theme = StenoDesign.theme(for: controller.preferences)

        HStack(spacing: 0) {
            sidebar(theme: theme)
            Divider().overlay(theme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    sectionContent(theme: theme)

                    if selectedSection != .appearance {
                        footer(theme: theme)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
        }
        .onAppear {
            guard !didLoad else { return }
            preferencesDraft = controller.preferences
            didLoad = true
        }
        .onChange(of: controller.preferences.appearance) { newAppearance in
            preferencesDraft.appearance = newAppearance
        }
    }

    private func sidebar(theme: StenoTheme) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SETTINGS")
                .font(StenoDesign.mono(size: 10, weight: .medium))
                .tracking(2)
                .foregroundStyle(theme.textMuted)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 10)

            ForEach(SettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.symbolName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(selectedSection == section ? theme.accent : theme.textMuted)
                            .frame(width: 14)
                        Text(section.title)
                            .font(StenoDesign.callout().weight(.medium))
                            .foregroundStyle(selectedSection == section ? theme.text : theme.textDim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selectedBackground(for: selectedSection == section, theme: theme))
                    )
                    .overlay(alignment: .leading) {
                        if selectedSection == section {
                            RoundedRectangle(cornerRadius: 999, style: .continuous)
                                .fill(theme.accent)
                                .frame(width: 2)
                                .padding(.vertical, 8)
                                .offset(x: -10)
                                .shadow(color: theme.accentGlow, radius: 8)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(selectedSection == section ? theme.selectedAccentBorder : .clear, lineWidth: StenoDesign.borderThin)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 4) {
                Text("BUILD")
                    .font(StenoDesign.mono(size: 9.5, weight: .medium))
                    .tracking(1.6)
                    .foregroundStyle(theme.textMuted)
                Text("v0.1.10 · macOS")
                    .font(StenoDesign.subheadline())
                    .foregroundStyle(theme.textDim)
                Text("swift 6 · whisper.cpp")
                    .font(StenoDesign.mono(size: 10, weight: .regular))
                    .foregroundStyle(theme.textMuted)
            }
            .padding(12)
            .background(Color.white.opacity(theme.isLight ? 0.74 : 0.025))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.line, lineWidth: StenoDesign.borderThin)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 214)
        .background(theme.ink1.opacity(0.55))
    }

    private func selectedBackground(for selected: Bool, theme: StenoTheme) -> some ShapeStyle {
        guard selected else {
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

    @ViewBuilder
    private func sectionContent(theme: StenoTheme) -> some View {
        switch selectedSection {
        case .appearance:
            AppearanceSettingsSection(appearance: appearanceBinding)
        case .permissions:
            PermissionsSettingsSection()
        case .recording:
            RecordingSettingsSection(
                preferences: $preferencesDraft,
                hotkeyRegistrationMessage: controller.hotkeyRegistrationMessage
            )
        case .engine:
            EngineSettingsSection(preferences: $preferencesDraft, controller: controller)
        case .output:
            InsertionSettingsSection(preferences: $preferencesDraft)
        case .cleanup:
            CleanupStyleSettingsSection(preferences: $preferencesDraft)
        case .corrections:
            LexiconSettingsSection(preferences: $preferencesDraft)
        case .shortcuts:
            SnippetsSettingsSection(preferences: $preferencesDraft)
        case .media:
            MediaSettingsSection(preferences: $preferencesDraft)
        case .general:
            GeneralSettingsSection(
                preferences: $preferencesDraft,
                launchAtLoginWarning: controller.launchAtLoginWarning
            )
        }
    }

    private func footer(theme: StenoTheme) -> some View {
        HStack(spacing: 8) {
            Spacer()

            Button("Discard") {
                preferencesDraft = controller.preferences
            }
            .buttonStyle(StenoActionButtonStyle(theme: theme, tone: .ghost))
            .disabled(preferencesDraft == controller.preferences)

            Button("Save & Apply") {
                controller.applySettingsDraft(preferences: preferencesDraft)
            }
            .buttonStyle(StenoActionButtonStyle(theme: theme, tone: .primary))
            .disabled(preferencesDraft == controller.preferences)
        }
        .padding(.top, 4)
    }

    private var appearanceBinding: Binding<AppPreferences.Appearance> {
        Binding(
            get: { preferencesDraft.appearance },
            set: { newAppearance in
                preferencesDraft.appearance = newAppearance
                controller.saveAppearance(newAppearance)
            }
        )
    }
}
