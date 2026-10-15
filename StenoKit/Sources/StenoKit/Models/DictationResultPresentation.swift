import Foundation

/// The "After inserting" setting: what the overlay shows after a successful
/// insertion. Copies and problems always show.
public enum SuccessNoticeStyle: String, Sendable, Equatable, CaseIterable {
    /// A brief check, with words when the text was pasted and during the
    /// first `DictationResultPresentation.wordsNoticeLimit` dictations.
    case matters
    /// Always say where the text went.
    case always
    /// No overlay for a successful insertion. VoiceOver still announces it.
    case nothing

    /// A missing or unknown saved value is the default.
    public init(preferenceValue: String?) {
        self = preferenceValue.flatMap(Self.init(rawValue:)) ?? .matters
    }
}

/// What to present for a finished dictation.
public enum ResultPresentation: Sendable, Equatable {
    case overlay(OverlayState)
    /// Nothing is shown; VoiceOver hears `announcement`.
    case silent(announcement: String)
}

public enum DictationResultPresentation {
    /// Successful insertions say where the text went for this many dictations.
    public static let wordsNoticeLimit = 20

    /// The overlay result for a completed dictation, or nil when nothing was
    /// recognized as speech. `appName` is the app the text was meant for.
    public static func overlayResult(for result: InsertResult, appName: String?) -> OverlayResult? {
        let microphoneStopped = result.captureWarning != nil
        switch result.status {
        case .noSpeech:
            return nil
        case .inserted:
            if microphoneStopped { return .microphoneDisconnected(insertedPartial: true) }
            return .inserted(appName: appName, method: result.method == .accessibility ? .accessibility : .typed)
        case .copiedOnly:
            if result.pasteAttempted == true {
                if microphoneStopped { return .microphoneDisconnected(insertedPartial: true) }
                return .inserted(appName: appName, method: .pasted)
            }
            if result.copyReason == .clipboardChanged { return .notPasted }
            if microphoneStopped { return .microphoneDisconnected(insertedPartial: false) }
            return .copied(CopyReason(result.copyReason))
        case .failed:
            return .failed(savedInHistory: result.historyWarning == nil)
        }
    }

    /// Applies the "After inserting" rule. A paste is always said in words,
    /// because Steno cannot confirm where it landed.
    public static func presentation(
        of result: OverlayResult,
        style: SuccessNoticeStyle,
        successNoticesShown: Int
    ) -> ResultPresentation {
        guard case .inserted(let appName, let method) = result, method != .pasted else {
            return .overlay(.result(result, showsWords: true))
        }
        switch style {
        case .nothing:
            return .silent(announcement: insertedAnnouncement(appName: appName))
        case .always:
            return .overlay(.result(result, showsWords: true))
        case .matters:
            return .overlay(.result(result, showsWords: successNoticesShown < wordsNoticeLimit))
        }
    }

    /// True for a successful insertion shown with words, which counts toward
    /// `wordsNoticeLimit`.
    public static func isSuccessNoticeWithWords(_ state: OverlayState) -> Bool {
        guard case .result(.inserted, showsWords: true) = state else { return false }
        return true
    }

    /// The most characters of the inserted words the overlay is ever handed.
    public static let overlayWordsLimit = 200

    /// The first line of `text`, for the overlay to show under a successful insertion: the first
    /// line with any words in it, trimmed and bounded. Nil when there are none.
    public static func insertedWordsLine(of text: String?) -> String? {
        guard let text else { return nil }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(overlayWordsLimit)) }
        }
        return nil
    }

    /// The words the overlay may show under `state`, from a finished insertion. Only a successful
    /// insertion the "After inserting" rule says in words carries them (so "Show nothing" and the
    /// brief confirmation never do), and never text that was concealed for a secure field. A
    /// result with no words has none to show.
    public static func overlayWords(for result: InsertResult, state: OverlayState) -> String? {
        guard case .result(.inserted, showsWords: true) = state else { return nil }
        guard result.copyIsConcealed != true else { return nil }
        return insertedWordsLine(of: result.insertedText)
    }

    public static func insertedAnnouncement(appName: String?) -> String {
        guard let appName, !appName.isEmpty else { return "Inserted" }
        return "Inserted into \(appName)"
    }
}

extension CopyReason {
    /// The overlay wording for an insertion's copy reason. A changed
    /// clipboard is never a copy: it is `OverlayResult.notPasted`.
    public init(_ reason: InsertionCopyReason?) {
        switch reason {
        case .secureField: self = .secureField
        case .fieldChanged: self = .fieldChanged
        case .appChanged: self = .appChanged
        case .appNotResponding: self = .appNotResponding
        case .accessibilityOff: self = .accessibilityOff
        case .noTextField: self = .noTextField
        case .clipboardChanged, .other, nil: self = .other
        }
    }
}
