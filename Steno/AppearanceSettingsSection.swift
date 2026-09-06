import SwiftUI

struct AppearanceSettingsSection: View {
    @Binding var appearance: AppPreferences.Appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsCardWithSubtitle("Color", subtitle: "Changes save immediately.") {
                Picker("Appearance", selection: $appearance.mode) {
                    ForEach(StenoAppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Divider()
                Picker("Accent", selection: $appearance.accent) {
                    ForEach(StenoAccentStyle.allCases) { accent in
                        Text(accent.title).tag(accent)
                    }
                }
                .frame(maxWidth: 320)
                Text("Choose an accent for the recording control and navigation.")
                    .font(.system(size: 12)).foregroundStyle(StenoDesign.textSecondary)
            }
            Label("Steno follows your Mac's Reduce Motion and Reduce Transparency settings.", systemImage: "accessibility")
                .font(.system(size: 12)).foregroundStyle(StenoDesign.textSecondary)
        }
    }
}
