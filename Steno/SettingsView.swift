import SwiftUI
import StenoKit

enum SettingsSection: String, CaseIterable, Identifiable {
    case recording
    case engine
    case output
    case cleanup
    case corrections
    case shortcuts
    case media
    case permissions
    case appearance
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
            return "Speech model"
        case .output:
            return "Text output"
        case .cleanup:
            return "Cleanup"
        case .corrections:
            return "Word corrections"
        case .shortcuts:
            return "Text shortcuts"
        case .media:
            return "Media"
        case .general:
            return "General"
        }
    }

    var summary: String {
        switch self {
        case .recording: return "Choose how you start, finish, and preview dictation."
        case .engine: return "Choose a speech model for this Mac."
        case .output: return "Control how your words reach the app you're using."
        case .cleanup: return "Choose how Steno tidies your words while preserving what you mean."
        case .corrections: return "Help Steno get names, terms, and recurring words right."
        case .shortcuts: return "Turn a short spoken phrase into text you use often."
        case .media: return "Keep playback predictable while you dictate."
        case .permissions: return "Review the access Steno needs for dictation."
        case .appearance: return "Make Steno comfortable to use."
        case .general: return "Choose how Steno fits into your Mac."
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

/// Keeps edits local until the user applies them and rejects stale overwrites.
struct SettingsDraftState {
    private(set) var preferences: AppPreferences
    private(set) var savedPreferences: AppPreferences
    private(set) var hasConflictingUpdate = false

    init(saved preferences: AppPreferences) {
        self.preferences = preferences
        savedPreferences = preferences
    }

    mutating func edit(_ updatedPreferences: AppPreferences) {
        preferences = updatedPreferences
        if preferences == savedPreferences {
            hasConflictingUpdate = false
        }
    }

    mutating func reload(_ updatedPreferences: AppPreferences) {
        preferences = updatedPreferences
        savedPreferences = updatedPreferences
        hasConflictingUpdate = false
    }

    mutating func reconcile(_ updatedPreferences: AppPreferences) {
        if preferences == savedPreferences || preferences == updatedPreferences {
            reload(updatedPreferences)
            return
        }

        var previousWithUpdatedAppearance = savedPreferences
        previousWithUpdatedAppearance.appearance = updatedPreferences.appearance
        if previousWithUpdatedAppearance == updatedPreferences {
            preferences.appearance = updatedPreferences.appearance
        } else {
            hasConflictingUpdate = true
        }
        savedPreferences = updatedPreferences
        if preferences == savedPreferences {
            hasConflictingUpdate = false
        }
    }
}

struct SettingsView: View {
    @Binding var selectedSection: SettingsSection
    let showsSidebar: Bool
    @EnvironmentObject private var controller: DictationController
    @State private var draftState = SettingsDraftState(saved: .default)
    @State private var didLoad = false

    private var preferencesDraft: AppPreferences { draftState.preferences }
    private var hasConflictingUpdate: Bool { draftState.hasConflictingUpdate }
    private var preferencesBinding: Binding<AppPreferences> {
        Binding(get: { draftState.preferences }, set: { draftState.edit($0) })
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    init(selectedSection: Binding<SettingsSection> = .constant(.recording), showsSidebar: Bool = true) {
        self.showsSidebar = showsSidebar
        _selectedSection = selectedSection
    }

    var body: some View {
        let theme = StenoDesign.theme(for: controller.preferences)

        HStack(spacing: 0) {
            if showsSidebar {
                sidebar(theme: theme)
                Divider().overlay(theme.line)
            }
            settingsLayout(theme: theme)

        }
        .onAppear {
            guard !didLoad else { return }
            draftState.reload(controller.preferences)
            didLoad = true
        }
        .onChange(of: controller.preferences) { updatedPreferences in
            draftState.reconcile(updatedPreferences)
        }
    }

    @ViewBuilder
    private func settingsLayout(theme: StenoTheme) -> some View {
        switch StenoDesign.direction {
        case .signal:
            VStack(spacing: 0) {
                ScrollView {
                    settingsContent(theme: theme)
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(32)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if selectedSection != .appearance || preferencesDraft != controller.preferences {
                    Divider()
                    footer(theme: theme).padding(.horizontal, 32).padding(.vertical, 20)
                }
            }
        case .manuscript:
            ManuscriptSettingsLayout(content: settingsContent(theme: theme), footer: conditionalFooter(theme: theme), theme: theme)
        case .current:
            CurrentSettingsLayout(content: settingsContent(theme: theme), footer: conditionalFooter(theme: theme), theme: theme)
        }
    }

    private func settingsContent(theme: StenoTheme) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            if selectedSection != .appearance && selectedSection != .engine {
                VStack(alignment: .leading, spacing: 10) {
                    StenoPageTitle(selectedSection.title)
                    Text(selectedSection.summary)
                        .font(.system(size: 13)).foregroundStyle(theme.textDim)
                }
            }
            sectionContent(theme: theme)
        }
    }

    @ViewBuilder
    private func conditionalFooter(theme: StenoTheme) -> some View {
        if selectedSection != .appearance || preferencesDraft != controller.preferences {
            footer(theme: theme)
        }
    }

    private func sidebar(theme: StenoTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SETTINGS")
                .font(StenoDesign.mono(size: 10, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(theme.textDim)
                .padding(.horizontal, 20)
                .padding(.vertical, 31)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(SettingsSection.allCases) { section in
                        Button { selectedSection = section } label: {
                            Text(section.title)
                                .font(.system(size: 12, weight: selectedSection == section ? .semibold : .regular))
                                .foregroundStyle(selectedSection == section ? theme.text : theme.textDim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(selectedSection == section ? theme.ink2 : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.section.\(section.rawValue)")
                        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 10)
            }
            Text("Steno \(appVersion)")
                .font(StenoDesign.mono(size: 10))
                .foregroundStyle(theme.textDim)
                .padding(20)
        }
        .frame(width: 184)
        .background(theme.ink0)
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
                preferences: preferencesBinding,
                hotkeyRegistrationMessage: controller.hotkeyRegistrationMessage
            )
        case .engine:
            EngineSettingsSection(
                preferences: preferencesBinding,
                controller: controller,
                hasUnsavedChanges: preferencesDraft != controller.preferences
            )
        case .output:
            InsertionSettingsSection(preferences: preferencesBinding)
        case .cleanup:
            CleanupStyleSettingsSection(preferences: preferencesBinding)
        case .corrections:
            LexiconSettingsSection(preferences: preferencesBinding)
        case .shortcuts:
            SnippetsSettingsSection(preferences: preferencesBinding)
        case .media:
            MediaSettingsSection(preferences: preferencesBinding)
        case .general:
            GeneralSettingsSection(
                preferences: preferencesBinding,
                launchAtLoginWarning: controller.launchAtLoginWarning
            )
        }
    }

    private func footer(theme: StenoTheme) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                footerStatus(theme: theme)
                Spacer(minLength: 8)
                footerActions(theme: theme)
            }
            VStack(alignment: .leading, spacing: 14) {
                footerStatus(theme: theme)
                HStack { Spacer(minLength: 0); footerActions(theme: theme) }
            }
        }
        .padding(.top, 4)
    }

    private func footerStatus(theme: StenoTheme) -> some View {
        Text(hasConflictingUpdate ? "Settings changed elsewhere. Discard to reload before saving." : preferencesDraft == controller.preferences ? "No pending changes" : "You have unsaved changes")
            .font(.system(size: 12))
            .foregroundStyle(theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func footerActions(theme: StenoTheme) -> some View {
        HStack(spacing: 10) {
            Button("Discard") { draftState.reload(controller.preferences) }
                .buttonStyle(StenoActionButtonStyle(theme: theme, tone: .ghost))
                .disabled(preferencesDraft == controller.preferences)
                .accessibilityIdentifier("settings.discard")
            Button("Save changes") {
                controller.applySettingsDraft(preferences: preferencesDraft)
                // Accept synchronously normalized paths and options as the new draft baseline.
                draftState.reload(controller.preferences)
            }
            .buttonStyle(StenoActionButtonStyle(theme: theme, tone: .primary))
            .disabled(hasConflictingUpdate || preferencesDraft == controller.preferences)
            .accessibilityIdentifier("settings.save")
        }
        .fixedSize()
    }

    private var appearanceBinding: Binding<AppPreferences.Appearance> {
        Binding(
            get: { preferencesDraft.appearance },
            set: { newAppearance in
                var updatedPreferences = preferencesDraft
                updatedPreferences.appearance = newAppearance
                draftState.edit(updatedPreferences)
                controller.saveAppearance(newAppearance)
            }
        )
    }
}
