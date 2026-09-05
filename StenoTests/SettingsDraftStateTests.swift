import Foundation
import Testing
@testable import Steno

@Suite("Settings draft reconciliation")
struct SettingsDraftStateTests {
    @Test("A clean draft follows changes from another settings surface")
    func cleanDraftFollowsExternalChanges() {
        let initial = fixturePreferences()
        var state = SettingsDraftState(saved: initial)
        var external = initial
        external.hotkeys.optionPressToTalkEnabled.toggle()
        external.dictation.threadCount = 6
        state.reconcile(external)
        #expect(state.preferences == external)
        #expect(state.savedPreferences == external)
        #expect(!state.hasConflictingUpdate)
    }

    @Test("Conflicting external changes preserve unsaved edits and prevent stale saving")
    func conflictPreservesEdits() {
        let initial = fixturePreferences()
        var state = SettingsDraftState(saved: initial)
        var edited = initial
        edited.dictation.threadCount = 6
        state.edit(edited)
        var external = initial
        external.dictation.modelPath = "/fixture/new-model.bin"
        state.reconcile(external)
        #expect(state.preferences == edited)
        #expect(state.savedPreferences == external)
        #expect(state.hasConflictingUpdate)
    }

    @Test("Appearance updates preserve unsaved nonappearance changes")
    func appearanceUpdatesKeepDraft() {
        let initial = fixturePreferences()
        var state = SettingsDraftState(saved: initial)
        var edited = initial
        edited.media.pauseDuringHandsFree.toggle()
        state.edit(edited)
        var external = initial
        external.appearance.mode = .light
        external.appearance.accent = .rose
        state.reconcile(external)
        #expect(state.preferences.appearance == external.appearance)
        #expect(state.preferences.media == edited.media)
        #expect(!state.hasConflictingUpdate)
        #expect(state.preferences != state.savedPreferences)
    }

    @Test("An appearance update cannot erase a previously detected conflict")
    func appearancePreservesExistingConflict() {
        let initial = fixturePreferences()
        var state = SettingsDraftState(saved: initial)
        var edited = initial
        edited.dictation.threadCount = 6
        state.edit(edited)
        var external = initial
        external.hotkeys.optionPressToTalkEnabled.toggle()
        state.reconcile(external)
        external.appearance.accent = .emerald
        state.reconcile(external)
        #expect(state.hasConflictingUpdate)
        #expect(state.preferences.dictation.threadCount == 6)
        #expect(state.preferences.appearance == external.appearance)
        #expect(state.preferences.hotkeys == initial.hotkeys)
    }

    @Test("Editing back to the latest saved values clears a stale conflict")
    func editingBackToEqualityClearsConflict() {
        let initial = fixturePreferences()
        var state = SettingsDraftState(saved: initial)
        var edited = initial
        edited.dictation.threadCount = 6
        state.edit(edited)
        var external = initial
        external.hotkeys.optionPressToTalkEnabled.toggle()
        state.reconcile(external)
        #expect(state.hasConflictingUpdate)
        state.edit(external)
        #expect(!state.hasConflictingUpdate)
        #expect(state.preferences == state.savedPreferences)
        external.dictation.threadCount = 4
        state.edit(external)
        #expect(!state.hasConflictingUpdate)
    }

    @Test("An external update matching the user's draft resolves the conflict")
    func externalEqualityResolvesConflict() {
        let initial = fixturePreferences()
        var state = SettingsDraftState(saved: initial)
        var edited = initial
        edited.dictation.threadCount = 6
        state.edit(edited)
        var external = initial
        external.hotkeys.optionPressToTalkEnabled.toggle()
        state.reconcile(external)
        state.reconcile(edited)
        #expect(state.preferences == edited)
        #expect(state.savedPreferences == edited)
        #expect(!state.hasConflictingUpdate)
    }

    @Test("Explicit save accepts the normalized result instead of treating it as an external conflict")
    func normalizedSaveBecomesBaseline() {
        let initial = fixturePreferences()
        var state = SettingsDraftState(saved: initial)
        var edited = initial
        edited.dictation.threadCount = 99
        state.edit(edited)
        var normalized = edited
        normalized.dictation.threadCount = 16
        state.reload(normalized)
        state.reconcile(normalized)
        #expect(state.preferences.dictation.threadCount == 16)
        #expect(state.preferences == state.savedPreferences)
        #expect(!state.hasConflictingUpdate)
    }

    @Test("Discard replaces the entire draft with current saved preferences")
    func discardReloadsCurrentPreferences() {
        let initial = fixturePreferences()
        var state = SettingsDraftState(saved: initial)
        var edited = initial
        edited.general.showDockIcon.toggle()
        state.edit(edited)
        var external = initial
        external.media.pauseDuringHandsFree.toggle()
        state.reconcile(external)
        state.reload(external)
        #expect(state.preferences == external)
        #expect(!state.hasConflictingUpdate)
    }

    private func fixturePreferences() -> AppPreferences {
        var preferences = AppPreferences.default
        preferences.appearance.mode = .dark
        preferences.dictation.whisperCLIPath = "/fixture/whisper-cli"
        preferences.dictation.modelPath = "/fixture/model.bin"
        preferences.dictation.vadModelPath = "/fixture/vad.bin"
        preferences.dictation.threadCount = 8
        return preferences
    }
}
