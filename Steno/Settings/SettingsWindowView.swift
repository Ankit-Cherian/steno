import AppKit
import StenoKit
import SwiftUI

/// The Settings window: grouped sidebar with search, one page at a time, and the draft bar.
struct SettingsView: View {
    @EnvironmentObject private var controller: DictationController
    @ObservedObject private var session: SettingsSession
    private let externalSelection: Binding<SettingsSection>?

    init(session: SettingsSession = .shared) {
        self.session = session
        externalSelection = nil
    }

    /// Embeds Settings in another view that owns the selected page.
    init(selectedSection: Binding<SettingsSection>, showsSidebar: Bool = true) {
        session = .shared
        externalSelection = selectedSection
    }

    #if DEBUG
    init(
        previewDraftState: SettingsDraftState,
        selectedSection: Binding<SettingsSection> = .constant(.recording),
        showsSidebar: Bool = true
    ) {
        session = SettingsSession(previewDraft: previewDraftState, section: selectedSection.wrappedValue)
        externalSelection = nil
    }
    #endif

    var body: some View {
        window
            .onAppear {
                if let externalSelection { session.selectedSection = externalSelection.wrappedValue }
                session.microphone.connect(to: controller.microphone)
                session.attach(to: controller.preferences)
                Task { await controller.refreshLaunchAtLoginStatus() }
            }
            .onChange(of: controller.preferences) { session.reconcile($0) }
            .onChange(of: externalSelection?.wrappedValue) { value in
                if let value { session.selectedSection = value }
            }
            .onChange(of: session.selectedSection) { value in
                if externalSelection?.wrappedValue != value { externalSelection?.wrappedValue = value }
            }
    }

    /// An inset sidebar panel, the page on the plain ground, and the drafts bar, which stays on
    /// every page so Save Changes and Discard are always reachable.
    private var window: some View {
        GroveSettingsContent(accent: controller.preferences.appearance.accent) {
            HStack(spacing: 0) {
                GroveSettingsSidebar(session: session, changedSections: changedSections)
                VStack(spacing: 0) {
                    ScrollView {
                        SettingsPage(session: session)
                            .padding(.leading, 36)
                            .padding(.trailing, 34)
                            .padding(.top, 52)
                            .padding(.bottom, 24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(session.selectedSection)
                    SettingsDraftBar(session: session)
                }
            }
        }
    }

    private var changedSections: Set<SettingsSection> {
        Set(session.changes(against: controller.preferences).map(\.section))
    }
}

// MARK: - Page

/// The selected page, with bindings into the draft.
private struct SettingsPage: View {
    @ObservedObject var session: SettingsSession
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        switch session.selectedSection {
        case .recording:
            RecordingSettingsSection(
                preferences: draft,
                hotkeyRegistrationMessage: controller.hotkeyRegistrationMessage,
                pasteLastMessage: draft.wrappedValue.recording.pasteLastShortcut == controller.preferences.recording.pasteLastShortcut
                    ? controller.pasteLastShortcutMessage : ""
            )
        case .microphone:
            MicrophoneSettingsSection(preferences: draft, model: session.microphone)
        case .engine:
            EngineSettingsSection(
                preferences: draft,
                controller: controller,
                hasUnsavedChanges: session.preferences != controller.preferences
            )
        case .media:
            MediaSettingsSection(preferences: draft)
        case .cleanup:
            CleanupStyleSettingsSection(preferences: draft)
        case .corrections:
            LexiconSettingsSection(preferences: draft)
        case .shortcuts:
            SnippetsSettingsSection(preferences: draft)
        case .output:
            InsertionSettingsSection(preferences: draft)
        case .permissions:
            PermissionsSettingsSection()
        case .appearance:
            AppearanceSettingsSection(appearance: appearance)
        case .general:
            GeneralSettingsSection(
                preferences: draft,
                launchAtLoginWarning: controller.launchAtLoginWarning,
                launchAtLoginNeedsApproval: controller.launchAtLoginNeedsApproval,
                onOpenLoginItems: { controller.openLoginItemsSettings() }
            )
        }
    }

    private var draft: Binding<AppPreferences> {
        Binding(get: { session.preferences }, set: { session.edit($0) })
    }

    private var appearance: Binding<AppPreferences.Appearance> {
        Binding(
            get: { session.preferences.appearance },
            set: { session.applyAppearance($0, controller: controller) }
        )
    }
}

// MARK: - Draft bar

/// Pending changes, Save and Discard. Present on every drafted page.
struct SettingsDraftBar: View {
    @ObservedObject var session: SettingsSession
    @EnvironmentObject private var controller: DictationController
    @State private var lastAnnounced: SettingsDraftBarState?

    var body: some View {
        let state = SettingsDraftBarState.derive(
            draft: session.draft, saved: controller.preferences,
            saveError: controller.settingsSaveError, notice: session.saveNotice
        )
        bar(state)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Unsaved changes")
            .onChange(of: state) { newState in
                // Announce when changes first appear, and on saved or conflict; not on every edit.
                if case .pending = newState, case .pending = lastAnnounced { return }
                lastAnnounced = newState
                announce(newState)
            }
    }

    /// A raised rounded bar with the status on the left, Discard as a quiet pill
    /// and Save Changes in the accent, muted when there is nothing to save.
    private func bar(_ state: SettingsDraftBarState) -> some View {
        GroveDraftBarChrome {
            GroveDraftBarStatus(
                state: state,
                changes: session.changes(against: controller.preferences)
            )
            .layoutPriority(1)
            Spacer(minLength: 8)
            Button("Discard") { session.discard(controller: controller) }
                .buttonStyle(GroveFocusedButtonStyle(look: GroveDraftBarButtonStyle(kind: .discard), cornerRadius: 13))
                .groveFont(12, .medium)
                .disabled(!state.canDiscard)
                .fixedSize()
                .layoutPriority(2)
                .accessibilityIdentifier("settings.discard")
            if state != .modelConflict {
                Button {
                    session.save(controller: controller)
                } label: {
                    HStack(spacing: 5) {
                        Text(state == .saveFailed ? "Try Again" : "Save Changes")
                            .groveFont(12, .semibold)
                        if state.canSave, state != .saveFailed {
                            Text("⌘S")
                                .groveFont(11)
                                .opacity(0.7)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(GroveFocusedButtonStyle(look: GroveDraftBarButtonStyle(kind: .save), cornerRadius: 13))
                .fixedSize()
                .layoutPriority(2)
                .disabled(!state.canSave)
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityIdentifier("settings.save")
                .accessibilityHint(state == .externalConflict ? "Discard first to load the other changes" : "")
            }
        }
    }

    private func announce(_ state: SettingsDraftBarState) {
        guard state != .clean else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: state.message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}
