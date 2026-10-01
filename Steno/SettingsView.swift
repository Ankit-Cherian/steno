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
    enum ConflictCause: Equatable {
        /// Only the speech model changed, which happens when a download finishes.
        case modelChange
        case externalChange
    }

    private(set) var preferences: AppPreferences
    private(set) var savedPreferences: AppPreferences
    private(set) var conflictCause: ConflictCause?
    var hasConflictingUpdate: Bool { conflictCause != nil }

    init(saved preferences: AppPreferences) {
        self.preferences = preferences
        savedPreferences = preferences
    }

    mutating func edit(_ updatedPreferences: AppPreferences) {
        preferences = updatedPreferences
        if preferences == savedPreferences {
            conflictCause = nil
        }
    }

    /// Restores edits whose save failed, against the preferences still saved.
    mutating func restoreUnsaved(_ unsavedPreferences: AppPreferences, saved: AppPreferences) {
        preferences = unsavedPreferences
        savedPreferences = saved
        conflictCause = nil
    }

    mutating func reload(_ updatedPreferences: AppPreferences) {
        preferences = updatedPreferences
        savedPreferences = updatedPreferences
        conflictCause = nil
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
        } else if Self.onlyModelChanged(from: savedPreferences, to: updatedPreferences),
                  conflictCause != .externalChange {
            conflictCause = .modelChange
        } else {
            conflictCause = .externalChange
        }
        savedPreferences = updatedPreferences
        if preferences == savedPreferences {
            conflictCause = nil
        }
    }

    private static func onlyModelChanged(from old: AppPreferences, to new: AppPreferences) -> Bool {
        var withNewModel = old
        withNewModel.dictation.modelPath = new.dictation.modelPath
        withNewModel.dictation.vadModelPath = new.dictation.vadModelPath
        return withNewModel == new
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

    #if DEBUG
    init(previewDraftState: SettingsDraftState, selectedSection: Binding<SettingsSection> = .constant(.recording), showsSidebar: Bool = true) {
        self.showsSidebar = showsSidebar
        _selectedSection = selectedSection
        _draftState = State(initialValue: previewDraftState)
        _didLoad = State(initialValue: true)
    }
    #endif

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
            Task { await controller.refreshLaunchAtLoginStatus() }
            guard !didLoad else { return }
            draftState.reload(controller.preferences)
            didLoad = true
        }
        .onChange(of: controller.preferences) { updatedPreferences in
            draftState.reconcile(updatedPreferences)
        }
    }

    private func settingsLayout(theme: StenoTheme) -> some View {
        ManuscriptSettingsLayout(
            content: settingsContent(theme: theme),
            footer: conditionalFooter(theme: theme),
            theme: theme,
            showsFooter: showsFooter
        )
    }

    private func settingsContent(theme: StenoTheme) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                StenoPageTitle(selectedSection.title)
                    .accessibilityAddTraits(.isHeader)
            }
            sectionContent(theme: theme)
        }
    }

    /// Appearance saves as it changes, so its page shows the footer only for
    /// pending edits or a failed save.
    private var showsFooter: Bool {
        selectedSection != .appearance
            || preferencesDraft != controller.preferences
            || !controller.settingsSaveError.isEmpty
    }

    @ViewBuilder
    private func conditionalFooter(theme: StenoTheme) -> some View {
        if showsFooter {
            footer(theme: theme)
        }
    }

    private func sidebar(theme: StenoTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textDim)
                .padding(.horizontal, 20)
                .padding(.vertical, 31)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(SettingsSection.allCases) { section in
                        Button { selectedSection = section } label: {
                            Text(section.title)
                                .font(.system(size: 13, weight: selectedSection == section ? .medium : .regular))
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
                launchAtLoginWarning: controller.launchAtLoginWarning,
                launchAtLoginNeedsApproval: controller.launchAtLoginNeedsApproval,
                onOpenLoginItems: { controller.openLoginItemsSettings() }
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
        Text(footerStatusText)
            .font(.system(size: preferencesDraft == controller.preferences && controller.settingsSaveError.isEmpty && !hasConflictingUpdate ? 11 : 12))
            .foregroundStyle(theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footerStatusText: String {
        switch draftState.conflictCause {
        case .modelChange:
            return "A model download changed the saved speech model. Discard to reload, then make your changes again."
        case .externalChange:
            return "Settings changed elsewhere. Discard to reload before saving."
        case nil:
            break
        }
        if !controller.settingsSaveError.isEmpty {
            return "Save failed. \(controller.settingsSaveError)"
        }
        return preferencesDraft == controller.preferences ? "No pending changes" : "You have unsaved changes"
    }

    private func footerActions(theme: StenoTheme) -> some View {
        HStack(spacing: 10) {
            Button("Discard") {
                draftState.reload(controller.preferences)
                controller.clearSettingsSaveError()
            }
                .buttonStyle(SettingsFooterButtonStyle(theme: theme, tone: .ghost))
                .disabled(preferencesDraft == controller.preferences)
                .accessibilityIdentifier("settings.discard")
            Button("Save changes") {
                let submitted = preferencesDraft
                let save = controller.applySettingsDraft(preferences: submitted)
                // Accept synchronously normalized paths and options as the new draft baseline.
                draftState.reload(controller.preferences)
                Task {
                    guard await !save.value else { return }
                    draftState.restoreUnsaved(submitted, saved: controller.preferences)
                }
            }
            .buttonStyle(SettingsFooterButtonStyle(theme: theme, tone: .primary))
            .disabled(hasConflictingUpdate || preferencesDraft == controller.preferences)
            .accessibilityIdentifier("settings.save")
            .keyboardShortcut("s", modifiers: .command)
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

private struct SettingsFooterButtonStyle: ButtonStyle {
    let theme: StenoTheme
    let tone: StenoActionButtonStyle.Tone
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .frame(height: 30)
            .font(StenoDesign.callout().weight(.medium))
            .foregroundStyle(!isEnabled ? Color(nsColor: .disabledControlTextColor) : tone == .primary ? theme.accentInk : theme.text)
            .background(isEnabled && tone == .primary ? theme.accent.opacity(configuration.isPressed ? 0.92 : 1) : .clear)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(isEnabled ? theme.lineStrong : theme.line, lineWidth: StenoDesign.borderThin))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
