import SwiftUI
import StenoKit

struct CleanupSettingsSection: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        settingsCard("Cleanup") {
            Picker("Cleanup mode", selection: $controller.preferences.cleanup.mode) {
                Text("Local only").tag(CleanupMode.localOnly)
                Text("Cloud if configured").tag(CleanupMode.cloudIfConfigured)
            }
            .pickerStyle(.segmented)

            SecureField("OpenAI API Key", text: $controller.openAIAPIKey)
                .textFieldStyle(.roundedBorder)
            Text("Transcription stays local. Cloud mode sends text only for cleanup.")
                .font(StenoDesign.caption())
                .foregroundStyle(StenoDesign.textSecondary)
        }
    }
}
