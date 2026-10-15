import Foundation
import StenoKit

/// The facts the window's status pill and recovery strips are derived from.
struct WindowStatusInputs: Equatable {
    var lifecycle: RecordingLifecycleState = .idle
    var recordingStartedAt: Date?
    var microphone: PermissionDiagnostics.AccessStatus = .granted
    var accessibility: PermissionDiagnostics.AccessStatus = .granted
    var inputMonitoring: PermissionDiagnostics.AccessStatus = .granted
    var speechModelMissing = false
    /// Download progress in percent, when the download reports it.
    var downloadPercent: Int?
    /// Hold Option is on in Settings › Recording.
    var optionHold = true
    /// The hands-free key's name, such as "F18", when that shortcut is on.
    var handsFreeKeyName: String?

    var isRecording: Bool {
        lifecycle == .recordingPressToTalk || lifecycle == .recordingHandsFree
    }
}

extension QuillStatusPillState {
    /// The one status the window shows. Recording and transcribing come first, then the
    /// problems in the order they block dictation, then a download, then Ready. A permission
    /// that is off never reads as Ready; one that has not been asked yet is not a problem.
    static func derive(_ inputs: WindowStatusInputs, now: Date = Date()) -> QuillStatusPillState {
        if inputs.isRecording {
            let elapsed = inputs.recordingStartedAt.map { Int(max(0, now.timeIntervalSince($0))) } ?? 0
            return .listening(elapsedSeconds: elapsed)
        }
        if inputs.lifecycle == .transcribing { return .transcribing }
        if inputs.microphone == .denied { return .microphoneOff }
        if inputs.speechModelMissing { return .noSpeechModel }
        if inputs.accessibility == .denied { return .copyOnly }
        if inputs.inputMonitoring == .denied {
            return .shortcutKeyOff(RecoveryStrips.blockedKey(optionHold: inputs.optionHold, handsFreeKeyName: inputs.handsFreeKeyName))
        }
        if let percent = inputs.downloadPercent { return .downloading(percent: percent) }
        return .ready
    }

    /// Today already says ready, listening, transcribing and microphone off in its status line,
    /// so the pill only appears there for the other states.
    func isShown(onToday: Bool) -> Bool {
        guard onToday else { return true }
        switch self {
        case .ready, .listening, .transcribing, .microphoneOff: return false
        default: return true
        }
    }

    /// Where clicking the pill goes. Nil for states that need nothing.
    var settingsSection: SettingsSection? {
        switch self {
        case .microphoneOff, .copyOnly, .shortcutKeyOff: .permissions
        case .noSpeechModel, .downloading: .engine
        case .ready, .listening, .transcribing: nil
        }
    }
}

/// A problem or notice shown as a strip under the toolbar (R1). One component, one shape:
/// a title that names it, one sentence with the effect and the fix, one named button.
struct RecoveryStripModel: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case microphoneOff, accessibilityOff, inputMonitoringOff, speechModelMissing
        case downloading, storage, attention
    }

    enum Tone: Equatable { case caution, info }

    enum Action: Equatable {
        case openMicrophoneSettings
        case requestMicrophone
        case openAccessibilitySettings
        case openInputMonitoringSettings
        case openSettings(SettingsSection)
        case copyStorageText
        case revealStorageFile
    }

    let kind: Kind
    let tone: Tone
    let systemImage: String
    let title: String
    let body: String
    let primary: (title: String, action: Action)?
    let secondary: (title: String, action: Action)?
    let dismissible: Bool

    var id: Kind { kind }

    static func == (lhs: RecoveryStripModel, rhs: RecoveryStripModel) -> Bool {
        lhs.kind == rhs.kind && lhs.title == rhs.title && lhs.body == rhs.body
            && lhs.primary?.title == rhs.primary?.title && lhs.primary?.action == rhs.primary?.action
            && lhs.secondary?.title == rhs.secondary?.title && lhs.secondary?.action == rhs.secondary?.action
    }
}

/// Builds the strips for the window from controller state. Pure, so the copy and the order
/// are testable without a controller.
enum RecoveryStrips {
    struct Context {
        var status: WindowStatusInputs
        var handsFreeKeyName: String?
        /// Hold Option is on in Settings › Recording.
        var optionHold = true
        var modelName: String?
        var downloadingModelName: String?
        var storageNotice: StorageRecoveryNotice?
        var lastError: String = ""
        var hotkeyMessage: String = ""
        var recoverySection: SettingsSection = .recording
    }

    /// The shortcuts Input Monitoring lets Steno detect in other apps, as the strip names them:
    /// the ones that are on, or "your shortcuts" when neither dictation shortcut is.
    static func inputMonitoringKeys(optionHold: Bool, handsFreeKeyName: String?) -> String {
        switch (optionHold, handsFreeKeyName) {
        case (true, .some(let key)): "Option or \(key)"
        case (true, .none): "Option"
        case (false, .some(let key)): key
        case (false, .none): "your shortcuts"
        }
    }

    /// The one key Input Monitoring keeps from working in other apps, for the status pill:
    /// Option or the hands-free key when only that one is on. Nil when both are on or neither
    /// is, and the pill speaks of shortcuts in general.
    static func blockedKey(optionHold: Bool, handsFreeKeyName: String?) -> String? {
        switch (optionHold, handsFreeKeyName) {
        case (true, .none): "Option"
        case (false, .some(let key)): key
        default: nil
        }
    }

    /// `onToday`: the Today status line already shows the microphone problem.
    static func strips(for context: Context, onToday: Bool) -> [RecoveryStripModel] {
        var strips: [RecoveryStripModel] = []
        if let notice = context.storageNotice {
            strips.append(storage(notice))
        }
        if context.status.microphone == .denied, !onToday {
            strips.append(microphoneOff)
        }
        if context.status.speechModelMissing {
            strips.append(speechModelMissing(modelName: context.modelName))
        }
        if context.status.accessibility == .denied {
            strips.append(RecoveryStripModel(
                kind: .accessibilityOff, tone: .caution, systemImage: "lock",
                title: "Accessibility access is off",
                body: "Steno can’t insert text, so each dictation is copied instead. If it’s already on, turn it off and on again.",
                primary: ("Open System Settings", .openAccessibilitySettings), secondary: nil, dismissible: true))
        }
        if context.status.inputMonitoring == .denied {
            let keys = inputMonitoringKeys(optionHold: context.optionHold, handsFreeKeyName: context.handsFreeKeyName)
            strips.append(RecoveryStripModel(
                kind: .inputMonitoringOff, tone: .caution, systemImage: "lock",
                title: "Input Monitoring is off",
                body: "Steno can’t detect \(keys) while you’re in other apps. Turn on Steno in Privacy & Security › Input Monitoring.",
                primary: ("Open System Settings", .openInputMonitoringSettings), secondary: nil, dismissible: true))
        }
        if let downloading = context.downloadingModelName {
            let current = context.modelName.map { "Dictation keeps using \($0) until it finishes." }
                ?? "Dictation keeps using the current model until it finishes."
            strips.append(RecoveryStripModel(
                kind: .downloading, tone: .info, systemImage: "arrow.down.circle",
                title: "Downloading \(downloading)", body: current,
                primary: nil, secondary: nil, dismissible: true))
        }
        let attention = [context.lastError, context.hotkeyMessage].filter { !$0.isEmpty }
        if !attention.isEmpty {
            let message = attention.joined(separator: " ")
            let (title, body) = splitFirstSentence(message)
            strips.append(RecoveryStripModel(
                kind: .attention, tone: .caution, systemImage: "exclamationmark.triangle",
                title: title, body: body,
                primary: ("Open Settings", .openSettings(context.recoverySection)), secondary: nil, dismissible: true))
        }
        return strips
    }

    static let microphoneOff = RecoveryStripModel(
        kind: .microphoneOff, tone: .caution, systemImage: "mic",
        title: "Microphone access is off",
        body: "Turn on Steno in System Settings › Privacy & Security › Microphone.",
        primary: ("Open System Settings", .openMicrophoneSettings), secondary: nil, dismissible: false)

    static func speechModelMissing(modelName: String?) -> RecoveryStripModel {
        let file = modelName.map { "the \($0) model file" } ?? "the speech model file"
        return RecoveryStripModel(
            kind: .speechModelMissing, tone: .caution, systemImage: "arrow.down.circle",
            title: "Speech model not found",
            body: "Steno can’t find \(file), so it can’t dictate.",
            primary: ("Open Speech Model Settings", .openSettings(.engine)), secondary: nil, dismissible: false)
    }

    static func storage(_ notice: StorageRecoveryNotice) -> RecoveryStripModel {
        let (title, body) = splitFirstSentence(notice.message)
        var primary: (String, RecoveryStripModel.Action)?
        var secondary: (String, RecoveryStripModel.Action)?
        if notice.recoverableText != nil {
            primary = ("Copy Dictation", .copyStorageText)
        }
        if notice.fileURL != nil {
            if primary == nil { primary = ("Show in Finder", .revealStorageFile) } else { secondary = ("Show in Finder", .revealStorageFile) }
        }
        return RecoveryStripModel(
            kind: .storage, tone: .caution, systemImage: "doc",
            title: title, body: body, primary: primary, secondary: secondary, dismissible: true)
    }

    /// "History couldn't be read. Steno kept the file." → ("History couldn't be read", "Steno kept the file.")
    static func splitFirstSentence(_ message: String) -> (String, String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: ". ") else {
            return (trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed, "")
        }
        return (String(trimmed[..<range.lowerBound]), String(trimmed[range.upperBound...]))
    }
}
