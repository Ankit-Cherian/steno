import Foundation
import Testing
@testable import Steno
import StenoKit

/// The After inserting setting, the Paste Last Dictation shortcut and the
/// success notice count are optional, and files that hold them still load in
/// the released 1.0.0 and the older 0.1.10 decoders.
@Suite("Insertion behaviour preferences")
struct InsertionBehaviourPreferencesTests {
    private func preferencesWithNewFields() -> AppPreferences {
        var preferences = AppPreferences.default
        preferences.recording.afterInserting = "nothing"
        preferences.recording.pasteLastShortcut = "control+option+command+9"
        preferences.general.successNoticesShown = 7
        return preferences
    }

    @Test("New preferences leave every new field unset")
    func defaults() {
        let preferences = AppPreferences.default
        #expect(preferences.recording.afterInserting == nil)
        #expect(preferences.recording.pasteLastShortcut == nil)
        #expect(preferences.general.successNoticesShown == nil)
        #expect(preferences.recording.successNoticeStyle == .matters)
        #expect(preferences.recording.pasteLastGlobalShortcut == nil)
    }

    @Test("Each new field round-trips")
    func roundTrip() throws {
        let preferences = preferencesWithNewFields()
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded.recording.afterInserting == "nothing")
        #expect(decoded.recording.pasteLastShortcut == "control+option+command+9")
        #expect(decoded.general.successNoticesShown == 7)
        #expect(decoded.recording.successNoticeStyle == .nothing)
        #expect(decoded.recording.pasteLastGlobalShortcut?.displayName == "⌃⌥⌘V")
    }

    @Test("Unset fields are left out of the file")
    func unsetFieldsAreOmitted() throws {
        let json = try #require(String(data: JSONEncoder().encode(AppPreferences.default), encoding: .utf8))
        #expect(!json.contains("afterInserting"))
        #expect(!json.contains("pasteLastShortcut"))
        #expect(!json.contains("successNoticesShown"))
    }

    @Test("Release 1.0.0 reads a file with the new fields and keeps its own settings")
    func releasedDecoderReadsNewFields() throws {
        var preferences = preferencesWithNewFields()
        preferences.general.showDockIcon = false
        let data = try JSONEncoder().encode(preferences)
        let released = try JSONDecoder().decode(Released100Preferences.Preferences.self, from: data)
        #expect(released.general.showDockIcon == false)
        #expect(released.hotkeys.handsFreeGlobalKeyCode == preferences.hotkeys.handsFreeGlobalKeyCode)
    }

    @Test("Version 0.1.10 reads a file with the new fields")
    func legacyDecoderReadsNewFields() throws {
        let data = try JSONEncoder().encode(preferencesWithNewFields())
        #expect((try? JSONDecoder().decode(LegacyV0110Preferences.self, from: data)) != nil)
    }

    @Test("A file without the new fields, or with an unreadable count, keeps its other settings")
    func olderAndDamagedFiles() throws {
        let older = Data(#"{"general":{"showDockIcon":false}}"#.utf8)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: older)
        #expect(decoded.general.showDockIcon == false)
        #expect(decoded.general.successNoticesShown == nil)
        #expect(decoded.recording == AppPreferences.Recording())

        let damaged = Data(#"{"general":{"showDockIcon":false,"successNoticesShown":"many"}}"#.utf8)
        let repaired = try JSONDecoder().decode(AppPreferences.self, from: damaged)
        #expect(repaired.general.showDockIcon == false)
        #expect(repaired.general.successNoticesShown == nil)
    }

    @Test("A dictation counting toward the first 20 is not a conflicting settings change")
    func countIsNotAnEdit() {
        let initial = AppPreferences.default
        var state = SettingsDraftState(saved: initial)
        var edited = initial
        edited.media.pauseDuringHandsFree.toggle()
        state.edit(edited)

        var external = initial
        external.general.successNoticesShown = 3
        state.reconcile(external)

        #expect(!state.hasConflictingUpdate)
        #expect(state.preferences.media == edited.media)
        #expect(state.preferences.general.successNoticesShown == 3)
    }
}
