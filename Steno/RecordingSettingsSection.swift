import SwiftUI
import StenoKit

struct RecordingSettingsSection: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        settingsCard("Recording") {
            Toggle("Enable Option hold-to-talk", isOn: $controller.preferences.hotkeys.optionPressToTalkEnabled)

            Picker("Global hands-free key", selection: handsFreeKeyBinding) {
                Text("Disabled").tag(nil as UInt16?)
                Text("F13").tag(105 as UInt16?)
                Text("F14").tag(107 as UInt16?)
                Text("F15").tag(113 as UInt16?)
                Text("F16").tag(106 as UInt16?)
                Text("F17").tag(64 as UInt16?)
                Text("F18").tag(79 as UInt16?)
                Text("F19").tag(80 as UInt16?)
                Text("F20").tag(90 as UInt16?)
            }
            .pickerStyle(.menu)

            Text("Works from any app. Map your Siri/mic key to this in VIA.")
                .font(StenoDesign.caption())
                .foregroundStyle(StenoDesign.textSecondary)

            if !controller.hotkeyRegistrationMessage.isEmpty {
                Text(controller.hotkeyRegistrationMessage)
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.error)
            }
        }
    }

    private var handsFreeKeyBinding: Binding<UInt16?> {
        Binding(
            get: { controller.preferences.hotkeys.handsFreeGlobalKeyCode },
            set: { controller.preferences.hotkeys.handsFreeGlobalKeyCode = $0 }
        )
    }
}
