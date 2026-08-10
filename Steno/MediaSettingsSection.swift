import SwiftUI

struct MediaSettingsSection: View {
    @Binding var preferences: AppPreferences

    var body: some View {
        settingsCard("Media") {
            Toggle("Pause music/video during hold-to-talk (Option)",
                   isOn: $preferences.media.pauseDuringPressToTalk)
            Toggle("Pause music/video during hands-free dictation",
                   isOn: $preferences.media.pauseDuringHandsFree)
            Text("Steno resumes only media it verified that it paused. Media that was already paused stays paused.")
                .font(StenoDesign.caption())
                .foregroundStyle(StenoDesign.textSecondary)
                .padding(.leading, StenoDesign.xxs)
        }
    }
}
