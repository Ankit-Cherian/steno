import SwiftUI

struct MediaSettingsSection: View {
    @Binding var preferences: AppPreferences

    var body: some View {
        settingsCard("During dictation") {
            settingsToggle(
                "Pause media during hold-to-talk",
                description: "Pause music and video while you hold Option.",
                isOn: $preferences.media.pauseDuringPressToTalk
            )
            Divider()
            settingsToggle(
                "Pause media during hands-free dictation",
                isOn: $preferences.media.pauseDuringHandsFree
            )
            Divider()
            Label {
                Text("Steno resumes only media it verified that it paused. Media that was already paused stays paused.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "play.pause")
            }
            .font(StenoDesign.caption())
            .foregroundStyle(StenoDesign.textSecondary)
        }
    }
}
