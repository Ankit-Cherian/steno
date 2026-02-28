import SwiftUI
import StenoKit

struct SettingsView: View {
    @EnvironmentObject private var controller: DictationController
    @State private var preferencesDraft: AppPreferences = .default

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StenoDesign.lg) {
                PermissionsSettingsSection()
                RecordingSettingsSection(
                    preferences: $preferencesDraft,
                    hotkeyRegistrationMessage: controller.hotkeyRegistrationMessage
                )
                EngineSettingsSection(
                    preferences: $preferencesDraft,
                    controller: controller
                )
                InsertionSettingsSection(preferences: $preferencesDraft)
                MediaSettingsSection(preferences: $preferencesDraft)
                LexiconSettingsSection(preferences: $preferencesDraft)
                CleanupStyleSettingsSection(preferences: $preferencesDraft)
                SnippetsSettingsSection(preferences: $preferencesDraft)
                GeneralSettingsSection(
                    preferences: $preferencesDraft,
                    launchAtLoginWarning: controller.launchAtLoginWarning
                )

                // Bottom actions
                HStack(spacing: StenoDesign.sm) {
                    Button("Save & Apply") {
                        controller.applySettingsDraft(preferences: preferencesDraft)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StenoDesign.accent)

                    Spacer()
                }
            }
            .padding(.vertical, StenoDesign.lg)
        }
        .onAppear {
            preferencesDraft = controller.preferences
        }
    }
}
