import StenoKit
import SwiftUI

/// The one line at the top of Today that says what state Steno is in and how to start.
enum TodayStatus: Equatable {
    case ready
    /// `startedHere`: dictating from Steno's own window copies the text instead of inserting.
    case recording(startedAt: Date?, startedHere: Bool)
    case transcribing
    case microphoneOff
    case microphoneNotAsked

    static func derive(lifecycle: RecordingLifecycleState, microphone: PermissionDiagnostics.AccessStatus,
                       recordingStartedAt: Date?, startedHere: Bool) -> TodayStatus {
        switch lifecycle {
        case .recordingPressToTalk, .recordingHandsFree:
            return .recording(startedAt: recordingStartedAt, startedHere: startedHere)
        case .transcribing:
            return .transcribing
        case .idle:
            switch microphone {
            case .denied: return .microphoneOff
            case .unknown, .granted: return .ready
            }
        }
    }
}

/// The shortcuts the ready line describes.
struct TodayShortcuts: Equatable {
    var optionHold: Bool
    var handsFreeKey: String?
    /// Shortcuts are on but cannot be heard in other apps until Input Monitoring is allowed.
    var needsInputMonitoring = false

    init(optionHold: Bool, handsFreeKey: String?, needsInputMonitoring: Bool = false) {
        self.optionHold = optionHold
        self.handsFreeKey = handsFreeKey
        self.needsInputMonitoring = needsInputMonitoring
    }

    /// The shortcuts that work in other apps: none while Input Monitoring is denied.
    init(_ hotkeys: AppPreferences.Hotkeys, inputMonitoring: PermissionDiagnostics.AccessStatus = .granted) {
        let option = hotkeys.optionPressToTalkEnabled
        let key = hotkeys.handsFreeGlobalKeyCode.flatMap(HandsFreeKey.displayName(for:))
        if inputMonitoring == .denied, option || key != nil {
            self.init(optionHold: false, handsFreeKey: nil, needsInputMonitoring: true)
        } else {
            self.init(optionHold: option, handsFreeKey: key)
        }
    }
}

/// "1:42", updated once a second from the recording's start date. Only this text redraws.
struct ElapsedText: View {
    let startedAt: Date?

    var body: some View {
        if let startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(QuillStatusPillState.elapsed(Int(max(0, context.date.timeIntervalSince(startedAt)))))
                    .monospacedDigit()
            }
        } else {
            Text(QuillStatusPillState.elapsed(0)).monospacedDigit()
        }
    }
}
