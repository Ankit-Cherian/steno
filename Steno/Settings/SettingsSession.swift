import Combine
import Foundation
import StenoKit

/// The Settings draft and window state, owned by the app rather than the window, so edits survive
/// navigating between pages and closing and reopening the window.
@MainActor
final class SettingsSession: ObservableObject {
    static let shared = SettingsSession()

    @Published private(set) var draft = SettingsDraftState(saved: .default)
    @Published private(set) var hasLoaded = false
    @Published var selectedSection: SettingsSection = .recording
    @Published var searchText = ""
    /// Shown in the draft bar after a save until the next edit.
    @Published private(set) var saveNotice: SaveNotice?

    let microphone: MicrophoneTestModel

    enum SaveNotice: Equatable {
        case saved
        /// Saved while a dictation was running; the runtime picks it up afterwards.
        case savedAfterCurrentDictation
    }

    init(microphone: MicrophoneTestModel = MicrophoneTestModel()) {
        self.microphone = microphone
    }

    #if DEBUG
    /// A session for previews and render tests, starting from `draft`.
    init(previewDraft: SettingsDraftState, section: SettingsSection = .recording, microphone: MicrophoneTestModel = MicrophoneTestModel()) {
        self.microphone = microphone
        draft = previewDraft
        hasLoaded = true
        selectedSection = section
    }

    func showPreviewSaveNotice(_ notice: SaveNotice?) {
        saveNotice = notice
    }
    #endif

    var preferences: AppPreferences { draft.preferences }

    /// Shows the page another part of the app asked for, and clears the request.
    func showRequestedSection(from router: SettingsRouter) {
        guard let section = router.requestedSection else { return }
        searchText = ""
        selectedSection = section
        router.requestedSection = nil
    }

    /// Loads the saved preferences the first time, and on later openings folds in anything that
    /// changed while the window was closed without discarding the draft. Only the draft and the
    /// page outlive the window: a Saved notice or a search from the last time does not come back.
    func attach(to saved: AppPreferences) {
        saveNotice = nil
        searchText = ""
        if hasLoaded {
            draft.reconcile(saved)
        } else {
            draft.reload(saved)
            hasLoaded = true
        }
    }

    func reconcile(_ saved: AppPreferences) {
        guard hasLoaded else { return }
        draft.reconcile(saved)
    }

    func edit(_ preferences: AppPreferences) {
        draft.edit(preferences)
        saveNotice = nil
    }

    func discard(controller: DictationController) {
        draft.reload(controller.preferences)
        controller.clearSettingsSaveError()
        saveNotice = nil
    }

    func save(controller: DictationController) {
        let submitted = draft.preferences
        let wasRecording = controller.isRecording
        let save = controller.applySettingsDraft(preferences: submitted, savedFrom: selectedSection)
        // Accept synchronously normalized paths and options as the new draft baseline.
        draft.reload(controller.preferences)
        Task {
            guard await save.value else {
                draft.restoreUnsaved(submitted, saved: controller.preferences)
                saveNotice = nil
                return
            }
            if draft.preferences == controller.preferences {
                saveNotice = wasRecording ? .savedAfterCurrentDictation : .saved
            }
        }
    }

    /// Appearance applies as it changes, outside the draft.
    func applyAppearance(_ appearance: AppPreferences.Appearance, controller: DictationController) {
        var updated = draft.preferences
        updated.appearance = appearance
        draft.edit(updated)
        controller.saveAppearance(appearance)
    }

    func changes(against saved: AppPreferences) -> [SettingsField] {
        guard draft.hasEdits(comparedWith: saved) else { return [] }
        return SettingsCatalog.changes(from: saved, to: draft.preferences)
    }
}

/// What the draft bar says. Derived, so the bar always matches the draft and the save result.
enum SettingsDraftBarState: Equatable {
    case clean
    case pending(String)
    case saved
    case savedAfterCurrentDictation
    case saveFailed
    case externalConflict
    case modelConflict

    static func derive(
        draft: SettingsDraftState,
        saved: AppPreferences,
        saveError: String,
        notice: SettingsSession.SaveNotice?
    ) -> SettingsDraftBarState {
        switch draft.conflictCause {
        case .modelChange: return .modelConflict
        case .externalChange: return .externalConflict
        case nil: break
        }
        let hasChanges = draft.hasEdits(comparedWith: saved)
        if !saveError.isEmpty, hasChanges { return .saveFailed }
        if hasChanges {
            return .pending(SettingsCatalog.summary(of: SettingsCatalog.changes(from: saved, to: draft.preferences)))
        }
        switch notice {
        case .saved: return .saved
        case .savedAfterCurrentDictation: return .savedAfterCurrentDictation
        case nil: return .clean
        }
    }

    var message: String {
        switch self {
        case .clean: "No unsaved changes"
        case .pending(let summary): summary
        case .saved: "Saved"
        case .savedAfterCurrentDictation: "Saved. Applies after the current dictation."
        case .saveFailed: "Couldn’t save. Your changes are still here."
        case .externalConflict: "Settings changed outside this window. Discard to load them."
        case .modelConflict: "A download changed your speech model. Discard to load it, then make your changes again."
        }
    }

    var canSave: Bool {
        switch self {
        case .pending, .saveFailed: true
        default: false
        }
    }

    var canDiscard: Bool {
        switch self {
        case .pending, .saveFailed, .externalConflict, .modelConflict: true
        default: false
        }
    }

}
