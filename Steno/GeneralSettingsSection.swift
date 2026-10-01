import SwiftUI

struct GeneralSettingsSection: View {
    @Binding var preferences: AppPreferences
    let launchAtLoginWarning: String
    var launchAtLoginNeedsApproval = false
    var onOpenLoginItems: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsCard("Startup and visibility") {
                settingsToggle("Launch at login", isOn: $preferences.general.launchAtLoginEnabled)
                if !launchAtLoginWarning.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: StenoDesign.sm) {
                        Text(launchAtLoginWarning)
                            .font(StenoDesign.caption())
                            .foregroundStyle(launchAtLoginNeedsApproval ? StenoDesign.warning : StenoDesign.error)
                            .fixedSize(horizontal: false, vertical: true)
                        if launchAtLoginNeedsApproval {
                            Spacer(minLength: StenoDesign.sm)
                            Button("Open Login Items", action: onOpenLoginItems)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .fixedSize()
                        }
                    }
                }
                Divider()
                settingsToggle("Show Dock icon", isOn: $preferences.general.showDockIcon)
            }
            settingsCard("Welcome guide") {
                settingsToggle(
                    "Open the setup guide",
                    description: "The setup guide opens when you save.",
                    isOn: $preferences.general.showOnboarding
                )
            }
        }
    }
}
