import Foundation

/// Why a dictation went to the clipboard instead of into the field. Set where
/// the decision is made, so nothing downstream has to read message text.
public enum InsertionCopyReason: String, Sendable, Codable, Equatable {
    /// The field was secure, most likely a password field.
    case secureField
    /// Focus moved to another field before the text could be inserted.
    case fieldChanged
    /// Another app was in front when the text was ready.
    case appChanged
    /// The target app did not answer in time.
    case appNotResponding
    /// Steno lacks the Accessibility permission it needs to paste.
    case accessibilityOff
    /// No text field was focused, for example in Steno's own window.
    case noTextField
    /// Another app wrote to the clipboard after Steno did, so pasting would
    /// have inserted someone else's text. Nothing was pasted.
    case clipboardChanged
    /// Any other reason, including a canceled paste.
    case other

    /// The reason for a target that could not be used at the commit point.
    public init(_ reason: EditorTargetUnavailableReason) {
        switch reason {
        case .secureOrProtectedElement:
            self = .secureField
        case .timedOut:
            self = .appNotResponding
        case .accessibilityPermissionMissing:
            self = .accessibilityOff
        case .applicationUnavailable, .applicationNotFrontmost, .bundleIdentifierMismatch,
             .processIdentityUnavailable:
            self = .appChanged
        case .focusedWindowUnavailable, .focusedElementUnavailable, .unsupportedElement,
             .selectionUnavailable, .malformedSelection, .characterCountUnavailable,
             .parameterizedTextUnavailable, .targetChanged, .selectedTextNotSettable:
            self = .fieldChanged
        case .cancelled, .accessibilityError:
            self = .other
        }
    }
}
