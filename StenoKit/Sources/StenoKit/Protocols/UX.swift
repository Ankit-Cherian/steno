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
}

/// An opaque token ensuring media is only resumed if it was actually paused.
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
    /// Shows the overlay with the given state.
    func show(state: OverlayState)

    /// Hides the overlay.
    func hide()
}

/// Pauses and resumes system media playback during recording sessions.
///
/// Uses a token-based system to prevent spurious resume. Runs on MainActor.
@MainActor
public protocol MediaInterruptionService: AnyObject {
    /// Pauses any active media playback and returns a token for resuming later.
    ///
    /// Returns `nil` if no media was paused (e.g., nothing was playing).
    func beginInterruption() async -> MediaInterruptionToken?

    /// Resumes media playback using the given token.
    ///
    /// Only resumes if the token matches an active interruption.
    func endInterruption(token: MediaInterruptionToken)
}
