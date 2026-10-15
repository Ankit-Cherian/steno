import SwiftUI

struct AppearanceSettingsSection: View {
    @Binding var appearance: AppPreferences.Appearance
    @EnvironmentObject private var controller: DictationController

    static let modeOrder: [StenoAppearanceMode] = [.system, .light, .dark]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(section: .appearance, intro: "Changes here save immediately.")
            if saveFailed {
                HStack(spacing: 10) {
                    SettingsCautionLine(text: "Appearance couldn’t be saved. Steno will use the previous appearance next time it opens.")
                    Spacer(minLength: 8)
                    Button("Try Again") { controller.saveAppearance(appearance) }
                        .settingsButton(.secondary)
                }
                .padding(.bottom, 12)
            }
            SettingsCard {
                SettingsRow(label: "Appearance") {
                    Picker("Appearance", selection: $appearance.mode) {
                        ForEach(Self.modeOrder, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            SettingsFootnote(
                text: "Steno follows your Mac’s text size, Reduce Motion, Reduce Transparency and Increase Contrast settings.",
                systemImage: "eye"
            )
        }
    }

    private var saveFailed: Bool {
        guard !controller.settingsSaveError.isEmpty, let target = controller.lastErrorTarget else { return false }
        return target.section == .appearance && target.message == controller.lastError
    }
}
