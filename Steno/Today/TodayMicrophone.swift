import Foundation
import SwiftUI

struct TodayMicrophoneChoice: Identifiable, Equatable {
    /// CoreAudio UID; nil means "follow the system input".
    let id: String?
    let name: String
}

/// The microphone pop-up on Today, backed by the controller's microphone model.
@MainActor
enum TodayMicrophone {
    /// The input dictation records from now, or nil when no input is listed.
    static func current(for controller: DictationController) -> TodayMicrophoneChoice? {
        #if DEBUG
        if controller.isIsolatedPreview { return previewChoice }
        #endif
        let model = controller.microphone
        guard let device = model.activeDevice else { return nil }
        return TodayMicrophoneChoice(id: model.selectedDeviceID, name: device.name)
    }

    /// The system input, then every connected input.
    static func choices(for controller: DictationController) -> [TodayMicrophoneChoice] {
        #if DEBUG
        if controller.isIsolatedPreview, let previewChoice { return [previewChoice] }
        #endif
        let devices = controller.microphone.devices
        guard !devices.isEmpty else { return [] }
        return [TodayMicrophoneChoice(id: nil, name: "System input")]
            + devices.map { TodayMicrophoneChoice(id: $0.id, name: $0.name) }
    }

    /// Saves the choice as `recording.inputDeviceID`, the way the menu bar and Settings do.
    static func select(_ choice: TodayMicrophoneChoice, for controller: DictationController) {
        controller.selectMicrophone(choice.id)
    }

    #if DEBUG
    /// The sample microphone shown in isolated previews and render tests.
    static var previewChoice: TodayMicrophoneChoice? = TodayMicrophoneChoice(id: nil, name: "MacBook Pro Microphone")
    #endif
}
