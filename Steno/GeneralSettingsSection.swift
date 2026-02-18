import SwiftUI

struct GeneralSettingsSection: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        settingsCard("General") {
            Toggle("Launch at login", isOn: $controller.preferences.general.launchAtLoginEnabled)
            Toggle("Show Dock icon", isOn: $controller.preferences.general.showDockIcon)
            Toggle("Show onboarding on next launch", isOn: $controller.preferences.general.showOnboarding)
            if !controller.launchAtLoginWarning.isEmpty {
                Text(controller.launchAtLoginWarning)
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.error)
            }
            Button("Re-run onboarding wizard") {
                controller.resetOnboarding()
            }
            .buttonStyle(.bordered)
        }
    }
}
