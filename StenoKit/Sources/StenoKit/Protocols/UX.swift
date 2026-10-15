import Foundation

/// Result of attempting to register a global hotkey.
public enum HotkeyRegistrationStatus: Sendable, Equatable {
    case registered
    /// The user turned the hands-free key off. This is a normal state, not a failure.
    case disabled
    case unavailable(reason: String)
}

/// The current state displayed in the floating status overlay.
public enum OverlayState: Sendable, Equatable {
    case listening(handsFree: Bool, elapsedSeconds: Int)
    case transcribing
    case inserted
    case copiedOnly
    case failure(message: String)
    case noSpeechDetected
    /// The outcome of a finished dictation. `showsWords` is false when a
    /// successful insertion should only be confirmed briefly.
    case result(OverlayResult, showsWords: Bool)
    case busy(OverlayBusyReason)
    /// A long recording was discarded; it can be restored until `undoUntil`.
    case discarded(undoUntil: Date)
}

public enum OverlayResult: Sendable, Equatable {
    case inserted(appName: String?, method: InsertionMethodKind)
    case copied(CopyReason)
    /// The clipboard changed before the paste, so the text is only in History.
    case notPasted
    case failed(savedInHistory: Bool)
    case microphoneDisconnected(insertedPartial: Bool)
    case transcriptionFailed
    case microphoneAccessOff
    case shortcutsUnavailable
    case speechModelMissing
}

public enum InsertionMethodKind: String, Sendable, Equatable {
    case typed
    case accessibility
    case pasted
}

public enum CopyReason: String, Sendable, Equatable {
    case secureField
    case fieldChanged
    case appChanged
    case appNotResponding
    case accessibilityOff
    case noTextField
    case other
}

public enum OverlayBusyReason: Sendable, Equatable {
    case stillFinishing
    case handsFreeDeferred
    case modelLoading
    /// Paste Last Dictation pressed while a dictation is in progress.
    case pasteWaitsForDictation
    /// Paste Last Dictation pressed with no dictation to paste.
    case nothingToPaste
}

extension OverlayState {
    /// The 1.0 state that presents the same outcome, for presenters that
    /// predate the 1.1 cases. Nil for states that are already 1.0 states.
    public var legacyEquivalent: OverlayState? {
        switch self {
        case .listening, .transcribing, .inserted, .copiedOnly, .failure, .noSpeechDetected:
            return nil
        case .result(let result, _):
            switch result {
            case .inserted: return .inserted
            case .copied: return .copiedOnly
            case .notPasted: return .failure(message: "Not pasted. Saved in History.")
            case .failed(let saved):
                return .failure(message: saved ? "Couldn\u{2019}t insert. Saved in History." : "Couldn\u{2019}t insert or save. Copy it now.")
            case .microphoneDisconnected(let inserted):
                return .failure(message: inserted ? "Microphone disconnected. Inserted what you said before that." : "Microphone disconnected. Copied what you said before that.")
            case .transcriptionFailed: return .failure(message: "Couldn\u{2019}t transcribe this recording.")
            case .microphoneAccessOff: return .failure(message: "Microphone access is off.")
            case .shortcutsUnavailable: return .failure(message: "Shortcuts unavailable. Open Steno.")
            case .speechModelMissing: return .failure(message: "Speech model not found. Open Steno.")
            }
        case .busy(let reason):
            switch reason {
            case .stillFinishing: return .failure(message: "Still finishing the last one")
            case .handsFreeDeferred: return .failure(message: "Starts when the last one finishes")
            case .modelLoading: return .failure(message: "Still loading the speech model")
            case .pasteWaitsForDictation: return .failure(message: "Finish this dictation first")
            case .nothingToPaste: return .failure(message: "No dictation to paste yet")
            }
        case .discarded:
            return .failure(message: "Recording discarded")
        }
    }
}

/// An opaque token used to coalesce overlapping media interruptions.
public struct MediaInterruptionToken: Sendable, Equatable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

/// Manages global hotkey registration for press-to-talk and hands-free toggle.
///
/// Runs on MainActor. Implementations handle platform-specific event monitoring
/// (e.g., CGEventTap on macOS).
@MainActor
public protocol HotkeyService: AnyObject {
    var onPressToTalkStart: (() -> Void)? { get set }
    var onPressToTalkStop: (() -> Void)? { get set }
    var onToggleHandsFree: (() -> Void)? { get set }
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)? { get set }

    var isOptionPressToTalkEnabled: Bool { get set }
    var globalToggleKeyCode: UInt16? { get set }

    /// Begins monitoring for configured hotkeys.
    func start()

    /// Stops all hotkey monitoring.
    func stop()

    /// Whether this service reports, after each press-to-talk start, if the
    /// press is a dictation or part of a keyboard shortcut. When it does,
    /// `onPressToTalkConfirmed` always comes before `onPressToTalkStop`, and
    /// `onPressToTalkDiscarded` replaces the stop and can follow a confirmation.
    /// A service that does not treats every start as confirmed.
    var confirmsPressToTalk: Bool { get }
    var onPressToTalkConfirmed: (() -> Void)? { get set }
    var onPressToTalkDiscarded: (() -> Void)? { get set }

    /// An optional shortcut for Paste Last Dictation. Nil registers nothing.
    var pasteLastShortcut: GlobalShortcut? { get set }
    var onPasteLastShortcut: (() -> Void)? { get set }
    /// Whether the shortcut could be registered; `.unavailable` says why not.
    var onPasteLastShortcutStatusChanged: ((HotkeyRegistrationStatus) -> Void)? { get set }
}

extension HotkeyService {
    public var confirmsPressToTalk: Bool { false }

    public var pasteLastShortcut: GlobalShortcut? {
        get { nil }
        set {}
    }

    public var onPasteLastShortcut: (() -> Void)? {
        get { nil }
        set {}
    }

    public var onPasteLastShortcutStatusChanged: ((HotkeyRegistrationStatus) -> Void)? {
        get { nil }
        set {}
    }

    public var onPressToTalkConfirmed: (() -> Void)? {
        get { nil }
        set {}
    }

    public var onPressToTalkDiscarded: (() -> Void)? {
        get { nil }
        set {}
    }
}

/// Displays and hides a floating status overlay during dictation.
///
/// Runs on MainActor. Implementations handle platform-specific overlays
/// (e.g., AppKit floating panels on macOS).
@MainActor
public protocol OverlayPresenter: AnyObject {
    /// Pre-creates the overlay window so the first `show` has no lazy-init stutter.
    func prepareWindow()

    /// Shows the overlay with the given state.
    func show(state: OverlayState)

    /// Shows a successful insertion with the first line of the words, which the controller offers
    /// only when they may be shown (see `DictationResultPresentation.overlayWords`). A presenter
    /// that has no use for them shows `state` alone.
    func show(state: OverlayState, insertedWords: String?)

    /// Enables or disables ephemeral local transcript previews for future
    /// recording sessions. This does not affect final transcription.
    func setLiveTranscriptEnabled(_ isEnabled: Bool)

    /// Pins the next recording session to the display containing the captured
    /// target point. Passing `nil` leaves display selection to the presenter.
    func pinNextSessionToDisplay(containing targetPoint: CGPoint?)

    /// Updates only the provisional transcript region of an active listening
    /// session. Implementations must not restart lifecycle presentation.
    func updateLiveTranscript(_ snapshot: LiveTranscriptionSnapshot)

    /// Clears the provisional display and preserves the active recording
    /// controls when the local preview can no longer continue.
    func showLiveTranscriptUnavailable()

    /// Draws the microphone level of the recording in progress: 0 (silence)
    /// to 1, already smoothed, at most 60 times a second, and 0 when capture
    /// ends. Implementations should write layer properties directly rather
    /// than view state.
    func updateInputLevel(_ level: Float)

    /// Hides the overlay.
    func hide()

    /// Called by the overlay's Undo button on a discarded recording.
    var onUndoDiscard: (() -> Void)? { get set }
    /// Called by the overlay's Copy button on a problem result.
    var onCopyResult: (() -> Void)? { get set }
}

public extension OverlayPresenter {
    func show(state: OverlayState, insertedWords _: String?) { show(state: state) }
    func updateInputLevel(_: Float) {}
    var onUndoDiscard: (() -> Void)? {
        get { nil }
        set {}
    }
    var onCopyResult: (() -> Void)? {
        get { nil }
        set {}
    }
    func setLiveTranscriptEnabled(_: Bool) {}
    func pinNextSessionToDisplay(containing _: CGPoint?) {}
    func updateLiveTranscript(_: LiveTranscriptionSnapshot) {}
    func showLiveTranscriptUnavailable() {}
}

/// Pauses and safely resumes system media playback during recording sessions.
///
/// Uses verified ownership tokens to coalesce overlapping interruptions and
/// prevent paused media from being started accidentally. Runs on MainActor.
@MainActor
public protocol MediaInterruptionService: AnyObject {
    /// Sends targeted Pause requests and returns a custody token when an
    /// application that was confirmed playing accepts the pause.
    ///
    /// Custody is tracked per application and starts provisional. It becomes
    /// resume ownership only once the application is observed to stop playing
    /// in response. An output stream that stays open, or closes later, proves
    /// nothing either way: media the listener paused earlier looks the same.
    /// Provisional custody that is never confirmed is dropped without a Play,
    /// as is custody whose process lineage breaks. Returns `nil` if no media
    /// pause can be tracked.
    func beginInterruption() async -> MediaInterruptionToken?

    /// Releases an interruption token and, after the final valid token, resumes
    /// only the exact media applications whose custody is still held.
    func endInterruption(token: MediaInterruptionToken) async
}
