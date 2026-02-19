import SwiftUI

struct MediaSettingsSection: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        settingsCard("Media") {
            Toggle("Pause music/video during hold-to-talk (Option)",
                   isOn: $controller.preferences.media.pauseDuringPressToTalk)
            Toggle("Pause music/video during hands-free dictation",
                   isOn: $controller.preferences.media.pauseDuringHandsFree)
            Text("Steno only sends play/pause when playback is clearly active.")
                .font(StenoDesign.caption())
                .foregroundStyle(StenoDesign.textSecondary)
        }
    }
}
