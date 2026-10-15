import SwiftUI
import StenoKit

enum SettingsSection: String, CaseIterable, Identifiable {
    case recording
    case microphone
    case engine
    case media
    case cleanup
    case corrections
    case shortcuts
    case output
    case permissions
    case appearance
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording: "Recording"
        case .microphone: "Microphone"
        case .engine: "Speech model"
        case .media: "Media"
        case .cleanup: "Cleanup"
        case .corrections: "Word corrections"
        case .shortcuts: "Text shortcuts"
        case .output: "Inserting text"
        case .permissions: "Permissions"
        case .appearance: "Appearance"
        case .general: "General"
        }
    }

    var group: SettingsGroup {
        switch self {
        case .recording, .microphone, .engine, .media: .dictation
        case .cleanup, .corrections, .shortcuts, .output: .text
        case .permissions, .appearance, .general: .thisMac
        }
    }
}

/// The three sidebar groups of the Settings window.
enum SettingsGroup: String, CaseIterable, Identifiable {
    case dictation
    case text
    case thisMac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "Dictation"
        case .text: "Text"
        case .thisMac: "This Mac"
        }
    }

    var sections: [SettingsSection] {
        SettingsSection.allCases.filter { $0.group == self }
    }
}

/// Keeps edits local until the user applies them and rejects stale overwrites.
struct SettingsDraftState {
    enum ConflictCause: Equatable {
        /// Only the speech model changed, which happens when a download finishes.
        case modelChange
        case externalChange
    }

    private(set) var preferences: AppPreferences
    private(set) var savedPreferences: AppPreferences
    private(set) var conflictCause: ConflictCause?
    var hasConflictingUpdate: Bool { conflictCause != nil }

    init(saved preferences: AppPreferences) {
        self.preferences = preferences
        savedPreferences = preferences
    }

    /// Whether the person has edited anything that `saved` does not already hold. A draft that
    /// still equals its own baseline has no edits, even in the moment before it catches up with
    /// a settings write made elsewhere, such as a dictation's success count.
    func hasEdits(comparedWith saved: AppPreferences) -> Bool {
        preferences != saved && preferences != savedPreferences
    }

    mutating func edit(_ updatedPreferences: AppPreferences) {
        preferences = updatedPreferences
        if preferences == savedPreferences {
            conflictCause = nil
        }
    }

    /// Restores edits whose save failed, against the preferences still saved.
    mutating func restoreUnsaved(_ unsavedPreferences: AppPreferences, saved: AppPreferences) {
        preferences = unsavedPreferences
        savedPreferences = saved
        conflictCause = nil
    }

    mutating func reload(_ updatedPreferences: AppPreferences) {
        preferences = updatedPreferences
        savedPreferences = updatedPreferences
        conflictCause = nil
    }

    mutating func reconcile(_ updatedPreferences: AppPreferences) {
        // Dictations update this count; that is not an edit to the settings.
        preferences.general.successNoticesShown = updatedPreferences.general.successNoticesShown
        savedPreferences.general.successNoticesShown = updatedPreferences.general.successNoticesShown
        if preferences == savedPreferences || preferences == updatedPreferences {
            reload(updatedPreferences)
            return
        }

        var previousWithUpdatedAppearance = savedPreferences
        previousWithUpdatedAppearance.appearance = updatedPreferences.appearance
        if previousWithUpdatedAppearance == updatedPreferences {
            preferences.appearance = updatedPreferences.appearance
        } else if Self.onlyModelChanged(from: savedPreferences, to: updatedPreferences),
                  conflictCause != .externalChange {
            conflictCause = .modelChange
        } else {
            conflictCause = .externalChange
        }
        savedPreferences = updatedPreferences
        if preferences == savedPreferences {
            conflictCause = nil
        }
    }

    private static func onlyModelChanged(from old: AppPreferences, to new: AppPreferences) -> Bool {
        var withNewModel = old
        withNewModel.dictation.modelPath = new.dictation.modelPath
        withNewModel.dictation.vadModelPath = new.dictation.vadModelPath
        return withNewModel == new
    }
}

