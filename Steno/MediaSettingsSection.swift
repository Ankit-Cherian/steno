import SwiftUI
import StenoKit

struct MediaSettingsSection: View {
    @Binding var preferences: AppPreferences
    var isMediaPausingSupported: Bool = MacMediaInterruptionService.isSupportedOnCurrentSystem

    var body: some View {
        settingsCard("During dictation") {
            settingsToggle(
                "Pause media during hold-to-talk",
                description: "Pause music and video while you hold Option.",
                isOn: pauseDuringPressToTalk
            )
            .disabled(!isMediaPausingSupported)
            .opacity(isMediaPausingSupported ? 1 : 0.5)
            Divider()
            settingsToggle(
                "Pause media during hands-free dictation",
                isOn: pauseDuringHandsFree
            )
            .disabled(!isMediaPausingSupported)
            .opacity(isMediaPausingSupported ? 1 : 0.5)
            Divider()
            Label {
                Text(captionText)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: isMediaPausingSupported ? "playpause" : "info.circle")
            }
            .font(StenoDesign.caption())
            .foregroundStyle(StenoDesign.textSecondary)
        }
    }

    var captionText: String {
        isMediaPausingSupported
            ? "Steno pauses apps that are playing when you start dictating and resumes only those. Media you paused yourself stays paused."
            : "Pausing media requires macOS 15 or later. Your choice is kept and takes effect after you update macOS."
    }

    var pauseDuringPressToTalk: Binding<Bool> {
        availabilityGated(\.media.pauseDuringPressToTalk)
    }

    var pauseDuringHandsFree: Binding<Bool> {
        availabilityGated(\.media.pauseDuringHandsFree)
    }

    /// Reads as off where media pausing is unavailable, without rewriting the
    /// saved choice, so it applies again once the system supports it.
    private func availabilityGated(_ keyPath: WritableKeyPath<AppPreferences, Bool>) -> Binding<Bool> {
        let preferences = $preferences
        let isSupported = isMediaPausingSupported
        return Binding(
            get: { isSupported && preferences.wrappedValue[keyPath: keyPath] },
            set: { newValue in
                guard isSupported else { return }
                preferences.wrappedValue[keyPath: keyPath] = newValue
            }
        )
    }
}
