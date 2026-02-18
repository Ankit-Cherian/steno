import SwiftUI

struct MediaSettingsSection: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        settingsCard("Media") {
            Toggle("Pause media during hold-to-talk (Option)",
                   isOn: $controller.preferences.media.pauseDuringPressToTalk)
            Toggle("Pause media during hands-free",
                   isOn: $controller.preferences.media.pauseDuringHandsFree)
            Text("Best-effort system play/pause control around recording sessions.")
                .font(StenoDesign.caption())
                .foregroundStyle(StenoDesign.textSecondary)
        }
    }
}
