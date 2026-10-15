import CoreGraphics
import Foundation

/// What the recording overlay shows for one `OverlayState`: width, quill, words, controls,
/// how long it stays and what VoiceOver hears. Pure, so every state can be checked without
/// drawing; `WaveformOverlayPresenter` renders it.
struct OverlayPresentation: Equatable {
    /// The capsule's fixed widths, in points at the default text size.
    enum Width: CGFloat, Equatable, CaseIterable {
        case hold = 220
        case handsFree = 300
        case problem = 340
    }

    enum Tone: Equatable {
        /// Full-strength label.
        case primary
        /// Secondary label (80 % white; full white under Increase Contrast).
        case quiet
        /// The brief "Inserted": quiet and one size smaller.
        case brief
        /// The last-minute countdown, in the caution colour and the monospaced face.
        case countdown
    }

    /// The one action a result can offer.
    enum Action: Equatable {
        case copy
        case openSettings
        case undo

        var title: String {
            switch self {
            case .copy: "Copy"
            case .openSettings: "Open Settings\u{2026}"
            case .undo: "Undo"
            }
        }
    }

    var width: Width
    var nib: NibLayer.Mode
    var mark: NibLayer.ResultMark?
    var label: String
    var tone: Tone
    /// Elapsed time shown beside the label, already formatted.
    var time: String?
    /// A key the label refers to, drawn as a keycap ("⌘V").
    var keyHint: String?
    var action: Action?
    var showsStop: Bool
    var showsDiscard: Bool
    /// How long the state stays before the overlay fades. Nil stays until the next state.
    var duration: TimeInterval?
    /// A notice that gives way to whatever was showing before it, rather than hiding.
    var restoresPrevious: Bool
    /// What VoiceOver announces when the state appears.
    var announcement: String?

    var isTimed: Bool { duration != nil }
}

extension OverlayPresentation {
    enum Durations {
        static let briefInserted: TimeInterval = 0.6
        static let insertedWithWords: TimeInterval = 2
        static let pasted: TimeInterval = 2
        static let copied: TimeInterval = 4
        static let noSpeech: TimeInterval = 2
        static let problem: TimeInterval = 6
        static let discarded: TimeInterval = 5
        static let busy: TimeInterval = 1.6
        /// The confirmation after the Copy button.
        static let copyConfirmation: TimeInterval = 0.8
    }

    /// A hold shows no time until it passes this many seconds.
    static let holdTimerThreshold = 10

    /// The words for a recording in progress.
    static func listeningLine(
        handsFree: Bool,
        elapsedSeconds: Int,
        limitSeconds: Int? = nil
    ) -> (label: String, time: String?, countdown: Bool) {
        let elapsed = max(0, elapsedSeconds)
        if let limitSeconds {
            return ("Stops in \(clock(max(0, limitSeconds - elapsed)))", nil, true)
        }
        if handsFree {
            return ("Hands-free", clock(elapsed), false)
        }
        return ("Listening", elapsed >= holdTimerThreshold ? clock(elapsed) : nil, false)
    }

    /// `m:ss`, as the boards write times ("0:14", "2:10").
    static func clock(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    /// The presentation for `state`.
    ///
    /// - Parameters:
    ///   - previousWidth: the width shown before, so Transcribing keeps it and × does not move.
    ///   - now: the current time, for the Undo window of a discarded recording.
    static func make(
        for state: OverlayState,
        previousWidth: Width? = nil,
        limitSeconds: Int? = nil,
        now: Date = Date()
    ) -> OverlayPresentation {
        switch state {
        case .listening(let handsFree, let elapsedSeconds):
            let line = listeningLine(handsFree: handsFree, elapsedSeconds: elapsedSeconds, limitSeconds: limitSeconds)
            return OverlayPresentation(
                width: handsFree ? .handsFree : .hold, nib: .live, mark: nil,
                label: line.label, tone: line.countdown ? .countdown : .primary, time: line.time,
                keyHint: nil, action: nil, showsStop: handsFree, showsDiscard: true,
                duration: nil, restoresPrevious: false,
                announcement: handsFree ? "Listening, hands-free" : "Listening"
            )
        case .transcribing:
            return OverlayPresentation(
                width: previousWidth ?? .hold, nib: .working, mark: nil,
                label: "Transcribing\u{2026}", tone: .primary, time: nil, keyHint: nil, action: nil,
                showsStop: false, showsDiscard: true, duration: nil, restoresPrevious: false,
                announcement: "Transcribing"
            )
        case .inserted:
            return make(for: .result(.inserted(appName: nil, method: .typed), showsWords: false))
        case .copiedOnly:
            return make(for: .result(.copied(.other), showsWords: true))
        case .failure(let message):
            return problem(message, announcement: message)
        case .noSpeechDetected:
            return OverlayPresentation(
                width: .hold, nib: .rest, mark: .microphone, label: "No speech detected", tone: .quiet,
                time: nil, keyHint: nil, action: nil, showsStop: false, showsDiscard: false,
                duration: Durations.noSpeech, restoresPrevious: false, announcement: "No speech detected"
            )
        case .result(let result, let showsWords):
            return make(for: result, showsWords: showsWords)
        case .busy(let reason):
            let label: String
            let announcement: String
            switch reason {
            case .stillFinishing:
                label = "Still finishing the last one"
                announcement = label
            case .handsFreeDeferred:
                label = "Starts when the last one finishes"
                announcement = "Hands-free starts when the last one finishes"
            case .modelLoading:
                label = "Still loading the speech model"
                announcement = label
            case .pasteWaitsForDictation:
                label = "Finish this dictation first"
                announcement = "Finish this dictation, then paste the last one"
            case .nothingToPaste:
                label = "No dictation to paste yet"
                announcement = label
            }
            return OverlayPresentation(
                width: .handsFree, nib: .working, mark: nil, label: label, tone: .quiet, time: nil,
                keyHint: nil, action: nil, showsStop: false, showsDiscard: false,
                duration: Durations.busy, restoresPrevious: true, announcement: announcement
            )
        case .discarded(let undoUntil):
            let remaining = min(Durations.discarded, max(0, undoUntil.timeIntervalSince(now)))
            return OverlayPresentation(
                width: .handsFree, nib: .rest, mark: nil, label: "Recording discarded", tone: .quiet,
                time: nil, keyHint: nil, action: remaining > 0 ? .undo : nil, showsStop: false,
                showsDiscard: false, duration: remaining > 0 ? remaining : Durations.copyConfirmation,
                restoresPrevious: false,
                announcement: remaining > 0 ? "Recording discarded. Undo available." : "Recording discarded"
            )
        }
    }

    private static func make(for result: OverlayResult, showsWords: Bool) -> OverlayPresentation {
        switch result {
        case .inserted(let appName, let method):
            let destination = appName.map { " into \($0)" } ?? ""
            if method == .pasted {
                return success("Pasted\(destination)", duration: Durations.pasted)
            }
            if showsWords {
                return success("Inserted\(destination)", duration: Durations.insertedWithWords)
            }
            var brief = success("Inserted", duration: Durations.briefInserted)
            brief.tone = .brief
            brief.announcement = "Inserted\(destination)"
            return brief
        case .copied(let reason):
            let label = copiedLabel(reason)
            return OverlayPresentation(
                width: .handsFree, nib: .rest, mark: .copy, label: label, tone: .primary, time: nil,
                keyHint: "\u{2318}V", action: nil, showsStop: false, showsDiscard: false,
                duration: Durations.copied, restoresPrevious: false,
                announcement: "\(label) Press Command V."
            )
        case .notPasted:
            return problem("Not pasted. Saved in History.", action: .copy)
        case .failed(let savedInHistory):
            return savedInHistory
                ? problem("Couldn\u{2019}t insert. Saved in History.", action: .copy)
                : problem("Couldn\u{2019}t insert or save. Copy it now.", action: .copy)
        case .microphoneDisconnected(let insertedPartial):
            return insertedPartial
                ? problem("Mic disconnected. Earlier words inserted.",
                          announcement: "Microphone disconnected. Inserted what you said before that.")
                : problem("Mic disconnected. Earlier words copied.",
                          announcement: "Microphone disconnected. Copied what you said before that.")
        case .transcriptionFailed:
            return problem("Couldn\u{2019}t transcribe this recording")
        case .microphoneAccessOff:
            return problem("Microphone access is off", action: .openSettings)
        case .shortcutsUnavailable:
            return problem("Shortcuts unavailable. Open Steno.")
        case .speechModelMissing:
            return problem("Speech model not found. Open Steno.")
        }
    }

    static func copiedLabel(_ reason: CopyReason) -> String {
        switch reason {
        case .secureField: "Password field. Copied."
        case .fieldChanged: "Field changed. Copied."
        case .appChanged: "App changed. Copied."
        case .appNotResponding: "App didn\u{2019}t respond. Copied."
        case .accessibilityOff: "Accessibility is off. Copied."
        case .noTextField: "No text field. Copied."
        case .other: "Copied."
        }
    }

    /// Shown for a moment after the Copy button.
    static var copyConfirmation: OverlayPresentation {
        OverlayPresentation(
            width: .problem, nib: .rest, mark: .copy, label: "Copied.", tone: .primary, time: nil,
            keyHint: "\u{2318}V", action: nil, showsStop: false, showsDiscard: false,
            duration: Durations.copyConfirmation, restoresPrevious: false,
            announcement: "Copied. Press Command V."
        )
    }

    private static func success(_ label: String, duration: TimeInterval) -> OverlayPresentation {
        OverlayPresentation(
            width: .hold, nib: .rest, mark: .check, label: label, tone: .primary, time: nil, keyHint: nil,
            action: nil, showsStop: false, showsDiscard: false, duration: duration, restoresPrevious: false,
            announcement: label
        )
    }

    private static func problem(
        _ label: String,
        action: Action? = nil,
        announcement: String? = nil
    ) -> OverlayPresentation {
        OverlayPresentation(
            width: .problem, nib: .rest, mark: .caution, label: label, tone: .primary, time: nil,
            keyHint: nil, action: action, showsStop: false, showsDiscard: false,
            duration: Durations.problem, restoresPrevious: false, announcement: announcement ?? label
        )
    }
}

/// The dismissal clock of a timed overlay state. Pointer hover holds it; leaving resumes
/// the remaining time, never less than `minimumAfterHover`. A hover counts only once the
/// pointer moves inside the overlay after the state appeared, so a pointer already resting
/// there does not freeze the overlay.
struct OverlayResultTimer: Equatable {
    static let minimumAfterHover: TimeInterval = 1

    private(set) var deadline: TimeInterval?
    private(set) var heldRemaining: TimeInterval?

    init() {}

    init(duration: TimeInterval, now: TimeInterval) {
        deadline = now + max(0, duration)
    }

    var isRunning: Bool { deadline != nil || heldRemaining != nil }
    var isHeld: Bool { heldRemaining != nil }

    /// The pointer moved inside the overlay.
    mutating func hold(now: TimeInterval) {
        guard let deadline else { return }
        heldRemaining = max(0, deadline - now)
        self.deadline = nil
    }

    /// The pointer left the overlay.
    mutating func release(now: TimeInterval) {
        guard let heldRemaining else { return }
        deadline = now + max(heldRemaining, Self.minimumAfterHover)
        self.heldRemaining = nil
    }

    mutating func cancel() {
        deadline = nil
        heldRemaining = nil
    }

    func isExpired(now: TimeInterval) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
    }

    /// Seconds until expiry, or nil while held or stopped.
    func delay(now: TimeInterval) -> TimeInterval? {
        deadline.map { max(0, $0 - now) }
    }
}
