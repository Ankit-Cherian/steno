import SwiftUI
import StenoKit

struct SettingsView: View {
    @EnvironmentObject private var controller: DictationController
    @State private var showClearAPIKeyDialog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StenoDesign.lg) {
                PermissionsSettingsSection()
                RecordingSettingsSection()
                EngineSettingsSection()
                CleanupSettingsSection()
                InsertionSettingsSection()
                MediaSettingsSection()
                LexiconSettingsSection()
                CleanupStyleSettingsSection()
                SnippetsSettingsSection()
                GeneralSettingsSection()

                // Bottom actions
                HStack(spacing: StenoDesign.sm) {
                    Button("Save & Apply") {
                        controller.savePreferences()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StenoDesign.accent)

                    Button("Save API Key") {
                        controller.saveAPIKey()
                    }
                    .buttonStyle(.bordered)

                    Button("Clear API Key") {
                        showClearAPIKeyDialog = true
                    }
                    .buttonStyle(.bordered)
                    .confirmationDialog(
                        "Clear API Key?",
                        isPresented: $showClearAPIKeyDialog,
                        titleVisibility: .visible
                    ) {
                        Button("Clear", role: .destructive) {
                            controller.clearAPIKey()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will remove your saved OpenAI API key. Cloud cleanup will fall back to local mode.")
                    }

                    Spacer()
                }
            }
            .padding(.vertical, StenoDesign.lg)
        }
    }
}
