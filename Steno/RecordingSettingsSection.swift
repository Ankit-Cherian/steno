import SwiftUI
import StenoKit

struct RecordingSettingsSection: View {
    @Binding var preferences: AppPreferences
    let hotkeyRegistrationMessage: String

    var body: some View {
        settingsCard("Recording") {
            Toggle("Enable Option hold-to-talk", isOn: $preferences.hotkeys.optionPressToTalkEnabled)

            VStack(alignment: .leading, spacing: StenoDesign.xxs) {
                Picker("Global hands-free key", selection: handsFreeKeyBinding) {
                    Text("Disabled").tag(nil as UInt16?)
                    Section("F1–F12 (built-in keyboard)") {
                        Text("F1").tag(122 as UInt16?)
                        Text("F2").tag(120 as UInt16?)
                        Text("F3").tag(160 as UInt16?)
                        Text("F4").tag(131 as UInt16?)
                        Text("F5").tag(96 as UInt16?)
                        Text("F6").tag(97 as UInt16?)
                        Text("F7").tag(98 as UInt16?)
                        Text("F8").tag(100 as UInt16?)
                        Text("F9").tag(101 as UInt16?)
                        Text("F10").tag(109 as UInt16?)
                        Text("F11").tag(103 as UInt16?)
                        Text("F12").tag(111 as UInt16?)
                    }
                    Section("F13–F20 (external keyboard)") {
                        Text("F13").tag(105 as UInt16?)
                        Text("F14").tag(107 as UInt16?)
                        Text("F15").tag(113 as UInt16?)
                        Text("F16").tag(106 as UInt16?)
                        Text("F17").tag(64 as UInt16?)
                        Text("F18").tag(79 as UInt16?)
                        Text("F19").tag(80 as UInt16?)
                        Text("F20").tag(90 as UInt16?)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: StenoDesign.pickerWidth, alignment: .leading)

                Text("Works from any app. F13–F20 work without extra setup. F1–F12 need standard function key mode in System Settings.")
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.textSecondary)
                    .padding(.leading, StenoDesign.xxs)
            }

            if !hotkeyRegistrationMessage.isEmpty {
                Text(hotkeyRegistrationMessage)
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.error)
            }
        }
    }

    private var handsFreeKeyBinding: Binding<UInt16?> {
        Binding(
            get: { preferences.hotkeys.handsFreeGlobalKeyCode },
            set: { preferences.hotkeys.handsFreeGlobalKeyCode = $0 }
        )
    }
}
