import SwiftUI
import StenoKit

struct MediaSettingsSection: View {
    @Binding var preferences: AppPreferences
    var isMediaPausingSupported: Bool = MacMediaInterruptionService.isSupportedOnCurrentSystem

    static let intro = "Steno pauses an app only when it can confirm the app is playing, and resumes only the apps it paused. Media you paused yourself stays paused."
    static let unsupportedNote = "Pausing media needs macOS 15 or later. Your choice is kept and takes effect after you update."
    /// Safari plays through a system helper that Steno can't tie to Safari, so it is never paused.
    static let safariNote = "Safari isn’t paused yet."
    /// The hold shortcut, said without naming a key: it reads true whether Hold Option is on or off.
    nonisolated static let holdLabel = "Pause while holding to dictate"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(section: .media, intro: Self.intro)
            SettingsCard {
                SettingsRow(
                    label: Self.holdLabel,
                    isDimmed: !isMediaPausingSupported
                ) {
                    SettingsSwitch(label: Self.holdLabel, isOn: pauseDuringPressToTalk)
                }
                SettingsRow(
                    label: "Pause during hands-free dictation",
                    isDimmed: !isMediaPausingSupported
                ) {
                    SettingsSwitch(label: "Pause during hands-free dictation", isOn: pauseDuringHandsFree)
                }
            }
            .disabled(!isMediaPausingSupported)
            if isMediaPausingSupported {
                SettingsFootnote(text: Self.safariNote, systemImage: "info.circle")
            } else {
                SettingsFootnote(text: Self.unsupportedNote, systemImage: "info.circle")
            }
        }
    }

    /// What the page says about pausing on this system.
    var captionText: String {
        isMediaPausingSupported ? Self.intro : Self.unsupportedNote
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
