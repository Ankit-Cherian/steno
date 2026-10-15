import SwiftUI
import StenoKit

struct RecordingSettingsSection: View {
    @Binding var preferences: AppPreferences
    let hotkeyRegistrationMessage: String
    /// Why the saved Paste Last Dictation shortcut isn't working, or empty.
    var pasteLastMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(section: .recording)
            SettingsCard {
                SettingsToggleRow(
                    label: "Hold Option to dictate",
                    help: "Release to finish. Option shortcuts such as Option-Arrow don’t start a dictation. To tell them apart, Steno notices that a key or mouse button was pressed in any app, never which one.",
                    isOn: $preferences.hotkeys.optionPressToTalkEnabled
                )
                .accessibilityIdentifier("settings.recording.option")
                SettingsRow(
                    label: "Hands-free key",
                    help: handsFreeHelp,
                    caution: hotkeyError
                ) {
                    handsFreePicker
                }
                SettingsRow(
                    label: "Paste last dictation",
                    help: "Off until you choose a shortcut.",
                    caution: pasteLastMessage.isEmpty ? nil : pasteLastMessage
                ) {
                    Picker("Paste last dictation", selection: $preferences.recording.pasteLastShortcut) {
                        ForEach(PasteLastShortcutChoices.options(
                            handsFreeKeyCode: preferences.hotkeys.handsFreeGlobalKeyCode,
                            saved: preferences.recording.pasteLastShortcut
                        )) { option in
                            Text(option.title).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            SettingsCard(title: "While recording") {
                SettingsToggleRow(
                    label: "Show live transcript",
                    help: "Words may change while you speak. Only the finished dictation is inserted and saved.",
                    isOn: $preferences.dictation.showLiveTranscriptWhileRecording
                )
                SettingsRow(
                    label: "After inserting",
                    help: "“Only when it matters” shows a brief check, and says where the text went when it was pasted and for your first 20 dictations. Copies and problems always show."
                ) {
                    Picker("After inserting", selection: $preferences.afterInserting) {
                        ForEach(AfterInsertingChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                .controlBelow()
                SettingsToggleRow(
                    label: "Use nearby text for continuation",
                    help: "Reads a little text around the insertion point to match spacing and capitals. Never saved.",
                    isOn: $preferences.dictation.useNearbyTextForContinuation
                )
            }
            SettingsFootnote(text: "Say “lowercase” before a phrase to start it with a small letter. Say “literal lowercase” to keep the word.")
        }
    }

    private var handsFreeHelp: String {
        "Press once to start and again to stop. F13–F20 work without setup; F1–F12 need standard function keys in System Settings. A recording stops after one hour."
    }

    /// The registration problem as the controller reports it. It describes the saved key and its
    /// real reason, so it does not change with an unsaved choice in the picker.
    private var hotkeyError: String? {
        hotkeyRegistrationMessage.isEmpty ? nil : hotkeyRegistrationMessage
    }

    private var handsFreePicker: some View {
        Picker("Hands-free key", selection: handsFreeKeyBinding) {
            Text("Disabled").tag(nil as UInt16?)
            Section("F1–F12 (built-in keyboard)") {
                ForEach(HandsFreeKeyName.builtIn, id: \.code) { key in
                    Text(key.name).tag(key.code as UInt16?)
                }
            }
            Section("F13–F20 (external keyboard)") {
                ForEach(HandsFreeKeyName.external, id: \.code) { key in
                    Text(key.name).tag(key.code as UInt16?)
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 104)
    }

    private var handsFreeKeyBinding: Binding<UInt16?> {
        Binding(
            get: { HandsFreeKey.pickerKeyCode(for: preferences.hotkeys.handsFreeGlobalKeyCode) },
            set: { preferences.hotkeys.handsFreeGlobalKeyCode = $0 }
        )
    }
}

/// Function-key names for the hands-free picker and messages.
enum HandsFreeKeyName {
    struct Key: Sendable {
        let code: UInt16
        let name: String
    }

    static let builtIn: [Key] = [
        .init(code: 122, name: "F1"), .init(code: 120, name: "F2"), .init(code: 99, name: "F3"),
        .init(code: 118, name: "F4"), .init(code: 96, name: "F5"), .init(code: 97, name: "F6"),
        .init(code: 98, name: "F7"), .init(code: 100, name: "F8"), .init(code: 101, name: "F9"),
        .init(code: 109, name: "F10"), .init(code: 103, name: "F11"), .init(code: 111, name: "F12"),
    ]

    static let external: [Key] = [
        .init(code: 105, name: "F13"), .init(code: 107, name: "F14"), .init(code: 113, name: "F15"),
        .init(code: 106, name: "F16"), .init(code: 64, name: "F17"), .init(code: 79, name: "F18"),
        .init(code: 80, name: "F19"), .init(code: 90, name: "F20"),
    ]

    static func name(for code: UInt16?) -> String? {
        guard let code else { return nil }
        return (builtIn + external).first { $0.code == code }?.name
    }
}
