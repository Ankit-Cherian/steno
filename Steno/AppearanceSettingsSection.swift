import SwiftUI

struct AppearanceSettingsSection: View {
    @Binding var appearance: AppPreferences.Appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StenoPageTitle("Appearance")
                .accessibilityAddTraits(.isHeader)
            Text("A comfortable place for your words. Changes save immediately.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            settingsCard("Color") {
                Picker("Appearance", selection: $appearance.mode) {
                    ForEach(StenoAppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Picker("Accent", selection: $appearance.accent) {
                    ForEach(StenoAccentStyle.allCases) { accent in
                        Text(accent.title).tag(accent)
                    }
                }
                .frame(maxWidth: 320)
                Text("Choose an accent for the recording control and navigation. Existing saved colors stay the same.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if StenoDesign.direction != .manuscript {
                settingsCard("Recording control") {
                    Picker(StenoDesign.direction == .signal ? "Corners" : "Shape", selection: $appearance.recordHeroStyle) {
                        Text(StenoDesign.direction == .signal ? "Defined corners" : "Rounded square")
                            .tag(StenoRecordHeroStyle.pill)
                        Text(StenoDesign.direction == .signal ? "Rounded corners" : "Circle")
                            .tag(StenoRecordHeroStyle.ring)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    Text(StenoDesign.direction == .signal ? "Corner style for the recording pad." : "The same recording controls and feedback are available in either shape.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Label("Steno follows your Mac's Reduce Motion and Reduce Transparency settings.", systemImage: "accessibility")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
