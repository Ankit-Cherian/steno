import SwiftUI

struct GeneralSettingsSection: View {
    @Binding var preferences: AppPreferences
    let launchAtLoginWarning: String

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsCard("Startup and visibility") {
                settingsToggle("Launch at login", isOn: $preferences.general.launchAtLoginEnabled)
                if !launchAtLoginWarning.isEmpty {
                    Text(launchAtLoginWarning)
                        .font(StenoDesign.caption())
                        .foregroundStyle(StenoDesign.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                settingsToggle("Show Dock icon", isOn: $preferences.general.showDockIcon)
            }
            settingsCard("Welcome guide") {
                settingsToggle("Show onboarding on next launch", isOn: $preferences.general.showOnboarding)
                Button("Show guide on next launch") {
                    preferences.general.showOnboarding = true
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
