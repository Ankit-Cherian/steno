import Foundation

/// Result of attempting to register a global hotkey.
public enum HotkeyRegistrationStatus: Sendable, Equatable {
    case registered
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

    /// Hides the overlay.
    func hide()
}

/// Pauses and safely resumes system media playback during recording sessions.
///
/// Uses verified ownership tokens to coalesce overlapping interruptions and
/// prevent paused media from being started accidentally. Runs on MainActor.
@MainActor
public protocol MediaInterruptionService: AnyObject {
    /// Sends targeted Pause requests and returns an ownership token only when
    /// active playback was confirmed and the pause transition was verified.
    ///
    /// Returns `nil` if no media was paused (e.g., nothing was playing).
    func beginInterruption() async -> MediaInterruptionToken?

    /// Releases an interruption token and, after the final valid token, resumes
    /// only the exact media applications whose pause transition was verified.
    func endInterruption(token: MediaInterruptionToken) async
}
