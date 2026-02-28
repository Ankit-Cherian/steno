import SwiftUI

struct MediaSettingsSection: View {
    @Binding var preferences: AppPreferences

    var body: some View {
        settingsCard("Media") {
            Toggle("Pause music/video during hold-to-talk (Option)",
                   isOn: $preferences.media.pauseDuringPressToTalk)
            Toggle("Pause music/video during hands-free dictation",
                   isOn: $preferences.media.pauseDuringHandsFree)
            Text("Steno only sends play/pause when playback is clearly active.")
                .font(StenoDesign.caption())
                .foregroundStyle(StenoDesign.textSecondary)
        }
    }
}
