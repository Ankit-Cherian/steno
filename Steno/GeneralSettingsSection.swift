import SwiftUI

struct GeneralSettingsSection: View {
    @Binding var preferences: AppPreferences
    let launchAtLoginWarning: String

    var body: some View {
        settingsCard("General") {
            Toggle("Launch at login", isOn: $preferences.general.launchAtLoginEnabled)
            Toggle("Show Dock icon", isOn: $preferences.general.showDockIcon)
            Toggle("Show onboarding on next launch", isOn: $preferences.general.showOnboarding)
            if !launchAtLoginWarning.isEmpty {
                Text(launchAtLoginWarning)
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.error)
            }
            Button("Re-run onboarding wizard") {
                preferences.general.showOnboarding = true
            }
            .buttonStyle(.bordered)
        }
    }
}
