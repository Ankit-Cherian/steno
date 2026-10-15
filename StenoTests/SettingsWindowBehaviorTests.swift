import Foundation
import Testing
@testable import Steno
@testable import StenoKit

@Suite("Settings window session", .serialized)
@MainActor
struct SettingsSessionTests {
    @Test("A draft survives closing and reopening the window")
    func draftSurvivesReopen() async {
        let controller = IsolatedAppPreview.makeController(populated: false)
        let session = SettingsSession(microphone: .preview(devices: [], testingAt: nil))
        session.attach(to: controller.preferences)
        var edited = session.preferences
        edited.hotkeys.handsFreeGlobalKeyCode = 64
        session.edit(edited)
        session.selectedSection = .general

        // Reopening attaches again with the same saved settings: nothing is reloaded or lost.
        session.attach(to: controller.preferences)
        #expect(session.preferences.hotkeys.handsFreeGlobalKeyCode == 64)
        #expect(session.selectedSection == .general)
        #expect(session.changes(against: controller.preferences).map(\.id) == ["handsFreeKey"])
        #expect(!session.draft.hasConflictingUpdate)
        await controller.teardownAndWait()
    }

    @Test("A change saved elsewhere while the window was closed blocks the stale draft on reopen")
    func externalChangeWhileClosed() async {
        let controller = IsolatedAppPreview.makeController(populated: false)
        let session = SettingsSession(microphone: .preview(devices: [], testingAt: nil))
        session.attach(to: controller.preferences)
        var edited = session.preferences
        edited.dictation.showLiveTranscriptWhileRecording.toggle()
        session.edit(edited)

        controller.preferences.dictation.threadCount += 1
        session.attach(to: controller.preferences)
        #expect(session.draft.conflictCause == .externalChange)
        #expect(session.preferences.dictation.showLiveTranscriptWhileRecording == edited.dictation.showLiveTranscriptWhileRecording)
        let bar = SettingsDraftBarState.derive(draft: session.draft, saved: controller.preferences, saveError: "", notice: nil)
        #expect(bar == .externalConflict)
        #expect(!bar.canSave)
        #expect(bar.canDiscard)
        await controller.teardownAndWait()
    }

    @Test("Appearance applies at once and keeps other unsaved edits")
    func appearanceAppliesImmediately() async {
        let controller = IsolatedAppPreview.makeController(populated: false)
        let session = SettingsSession(microphone: .preview(devices: [], testingAt: nil))
        session.attach(to: controller.preferences)
        var edited = session.preferences
        edited.media.pauseDuringHandsFree.toggle()
        session.edit(edited)

        var appearance = controller.preferences.appearance
        appearance.accent = .rose
        appearance.lineNumbersVisible = false
        session.applyAppearance(appearance, controller: controller)
        session.reconcile(controller.preferences)

        #expect(controller.preferences.appearance.accent == .rose)
        #expect(controller.preferences.appearance.showsLineNumbers == false)
        #expect(session.preferences.appearance == controller.preferences.appearance)
        #expect(session.changes(against: controller.preferences).map(\.id) == ["pauseHandsFree"])
        #expect(!session.draft.hasConflictingUpdate)
        await controller.teardownAndWait()
    }

    @Test("The router's requested section opens that page and is then cleared")
    func routerOpensRequestedSection() {
        let router = SettingsRouter()
        let session = SettingsSession(microphone: .preview(devices: [], testingAt: nil))
        session.searchText = "pause"
        router.requestedSection = .engine
        session.showRequestedSection(from: router)
        #expect(session.selectedSection == .engine)
        #expect(session.searchText.isEmpty)
        #expect(router.requestedSection == nil)

        session.selectedSection = .media
        session.showRequestedSection(from: router)
        #expect(session.selectedSection == .media)
    }

    @Test("Saving accepts the draft and says it was saved")
    func saveShowsSaved() async throws {
        let controller = IsolatedAppPreview.makeController(populated: false)
        let session = SettingsSession(microphone: .preview(devices: [], testingAt: nil))
        session.attach(to: controller.preferences)
        var edited = session.preferences
        edited.general.showDockIcon.toggle()
        edited.afterInserting = .always
        session.edit(edited)
        session.save(controller: controller)
        #expect(await eventuallyOnMain { session.saveNotice != nil })
        #expect(controller.preferences.general.showDockIcon == edited.general.showDockIcon)
        #expect(controller.preferences.afterInserting == .always)
        #expect(session.saveNotice == .saved)
        let bar = SettingsDraftBarState.derive(draft: session.draft, saved: controller.preferences, saveError: "", notice: session.saveNotice)
        #expect(bar == .saved)
        await controller.teardownAndWait()
    }

    @Test("Reopening the window starts from no unsaved changes and a full sidebar")
    func reopeningClearsTheSavedNoticeAndSearch() async throws {
        let controller = IsolatedAppPreview.makeController(populated: false)
        let session = SettingsSession(microphone: .preview(devices: [], testingAt: nil))
        session.attach(to: controller.preferences)
        var edited = session.preferences
        edited.general.showDockIcon.toggle()
        session.edit(edited)
        session.save(controller: controller)
        #expect(await eventuallyOnMain { session.saveNotice == .saved })
        session.searchText = "pause"

        // Closing the window and opening it again attaches the session once more.
        session.attach(to: controller.preferences)

        #expect(session.saveNotice == nil)
        #expect(session.searchText.isEmpty)
        #expect(SettingsDraftBarState.derive(
            draft: session.draft, saved: controller.preferences, saveError: "", notice: session.saveNotice
        ) == .clean)
        // The draft and the last page are what survive.
        #expect(session.preferences.general.showDockIcon == edited.general.showDockIcon)
        await controller.teardownAndWait()
    }

    @Test("Slash commands is drafted with the other Cleanup rows and saves the existing preference")
    func slashCommandsDraftsAndSaves() async throws {
        let controller = IsolatedAppPreview.makeController(populated: false)
        let session = SettingsSession(microphone: .preview(devices: [], testingAt: nil))
        session.attach(to: controller.preferences)
        let saved = controller.preferences.globalStyleProfile.commandPolicy
        let next: CommandPolicy = saved == .transform ? .passthrough : .transform
        var edited = session.preferences
        edited.globalStyleProfile.commandPolicy = next
        session.edit(edited)
        #expect(controller.preferences.globalStyleProfile.commandPolicy == saved)
        #expect(session.changes(against: controller.preferences).map(\.id) == ["commands"])
        #expect(session.changes(against: controller.preferences).map(\.section) == [.cleanup])
        let bar = SettingsDraftBarState.derive(draft: session.draft, saved: controller.preferences, saveError: "", notice: nil)
        #expect(bar == .pending("1 unsaved change: Slash commands"))

        session.save(controller: controller)
        #expect(await eventuallyOnMain { session.saveNotice != nil })
        #expect(controller.preferences.globalStyleProfile.commandPolicy == next)
        #expect(session.changes(against: controller.preferences).isEmpty)
        await controller.teardownAndWait()
    }
}

@Suite("Settings draft bar and catalog")
struct SettingsDraftBarTests {
    private func preferences() -> AppPreferences {
        var preferences = AppPreferences.default
        preferences.dictation.whisperCLIPath = "/fixture/whisper-cli"
        preferences.dictation.modelPath = "/fixture/ggml-small.en.bin"
        preferences.dictation.vadModelPath = "/fixture/ggml-silero.bin"
        return preferences
    }

    @Test("The bar names one change, lists two or three, and counts more")
    func summaries() {
        let saved = preferences()
        var draft = saved
        draft.hotkeys.handsFreeGlobalKeyCode = 64
        #expect(SettingsCatalog.summary(of: SettingsCatalog.changes(from: saved, to: draft)) == "1 unsaved change: Hands-free key")
        draft.dictation.showLiveTranscriptWhileRecording.toggle()
        #expect(SettingsCatalog.summary(of: SettingsCatalog.changes(from: saved, to: draft)) == "2 unsaved changes: Hands-free key, Show live transcript")
        draft.media.pauseDuringHandsFree.toggle()
        draft.general.showDockIcon.toggle()
        #expect(SettingsCatalog.summary(of: SettingsCatalog.changes(from: saved, to: draft)) == "4 unsaved changes")
        #expect(SettingsCatalog.summary(of: []) == "No unsaved changes")
    }

    @Test("Each bar state in priority order", arguments: [
        ("clean", SettingsDraftBarState.clean),
        ("pending", .pending("1 unsaved change: Hands-free key")),
        ("saved", .saved),
        ("later", .savedAfterCurrentDictation),
        ("failed", .saveFailed),
        ("conflict", .externalConflict),
        ("model", .modelConflict),
    ])
    func barStates(name: String, expected: SettingsDraftBarState) {
        let saved = preferences()
        var state = SettingsDraftState(saved: saved)
        var draft = saved
        if ["pending", "failed", "conflict", "model"].contains(name) {
            draft.hotkeys.handsFreeGlobalKeyCode = 64
            state.edit(draft)
        }
        var current = saved
        if name == "conflict" {
            current.dictation.threadCount += 1
            state.reconcile(current)
        } else if name == "model" {
            current.dictation.updateModelPath("/fixture/ggml-medium.en.bin")
            state.reconcile(current)
        }
        let notice: SettingsSession.SaveNotice? = name == "saved" ? .saved : (name == "later" ? .savedAfterCurrentDictation : nil)
        let derived = SettingsDraftBarState.derive(
            draft: state, saved: current, saveError: name == "failed" ? "Disk full" : "", notice: notice
        )
        #expect(derived == expected)
    }

    @Test("A clean draft stays clean while the saved settings change underneath it, before it catches up")
    func cleanDraftIgnoresSavedChangesUntilItReconciles() {
        let saved = preferences()
        let draft = SettingsDraftState(saved: saved)
        var ahead = saved
        ahead.general.successNoticesShown = (ahead.general.successNoticesShown ?? 0) + 1
        #expect(SettingsDraftBarState.derive(draft: draft, saved: ahead, saveError: "", notice: nil) == .clean)
        ahead.dictation.threadCount += 1
        let bar = SettingsDraftBarState.derive(draft: draft, saved: ahead, saveError: "", notice: nil)
        #expect(bar == .clean)
        #expect(!bar.canSave)
        #expect(!bar.canDiscard)

        // Once the draft reconciles, it follows the saved settings and is still clean.
        var caughtUp = draft
        caughtUp.reconcile(ahead)
        #expect(SettingsDraftBarState.derive(draft: caughtUp, saved: ahead, saveError: "", notice: nil) == .clean)
    }

    @Test("The sidebar marks no page for a clean draft while the saved settings change underneath it")
    @MainActor
    func sidebarMarksNothingForACleanDraftBehindTheSavedSettings() {
        let saved = preferences()
        let session = SettingsSession(previewDraft: SettingsDraftState(saved: saved))
        var ahead = saved
        ahead.dictation.threadCount += 1
        #expect(session.changes(against: ahead).isEmpty)

        var edited = session.preferences
        edited.hotkeys.handsFreeGlobalKeyCode = 64
        session.edit(edited)
        #expect(session.changes(against: saved).map(\.id) == ["handsFreeKey"])
    }

    @Test("An unsaved edit is still pending, and an external write over it is still a conflict")
    func editsStayPendingAndConflictsStayBlocked() {
        let saved = preferences()
        var state = SettingsDraftState(saved: saved)
        var edited = saved
        edited.hotkeys.handsFreeGlobalKeyCode = 64
        state.edit(edited)
        #expect(SettingsDraftBarState.derive(draft: state, saved: saved, saveError: "", notice: nil)
                == .pending("1 unsaved change: Hands-free key"))

        var external = saved
        external.dictation.threadCount += 1
        state.reconcile(external)
        let bar = SettingsDraftBarState.derive(draft: state, saved: external, saveError: "", notice: nil)
        #expect(bar == .externalConflict)
        #expect(!bar.canSave)
    }

    @Test("Save is offered only for pending changes and a failed save")
    func saveAvailability() {
        #expect(SettingsDraftBarState.pending("x").canSave)
        #expect(SettingsDraftBarState.saveFailed.canSave)
        #expect(!SettingsDraftBarState.externalConflict.canSave)
        #expect(!SettingsDraftBarState.modelConflict.canSave)
        #expect(!SettingsDraftBarState.clean.canSave)
        #expect(!SettingsDraftBarState.clean.canDiscard)
    }

    @Test("Search finds rows across sections in sidebar order", arguments: [
        ("pause", [SettingsSection.media]),
        ("microphone", [.microphone, .permissions]),
        ("model", [.engine]),
        ("slash", [.cleanup]),
        ("spoken formatting", []),
        ("dock", [.general]),
        ("dark", [.appearance]),
        ("accent", []),
        ("line numbers", []),
        ("zebra", []),
        ("   ", []),
    ])
    func search(query: String, sections: [SettingsSection]) {
        #expect(SettingsCatalog.search(query).map(\.section) == sections)
    }

    @Test("Search lists the matching rows of a section")
    func searchRows() {
        let media = SettingsCatalog.search("pause").first
        #expect(media?.rows == ["Pause while holding to dictate", "Pause during hands-free dictation"])
    }

    @Test("Every section has a group, and groups list sections in sidebar order")
    func groups() {
        #expect(SettingsGroup.dictation.sections == [.recording, .microphone, .engine, .media])
        #expect(SettingsGroup.text.sections == [.cleanup, .corrections, .shortcuts, .output])
        #expect(SettingsGroup.thisMac.sections == [.permissions, .appearance, .general])
        #expect(SettingsSection.output.title == "Inserting text")
        #expect(SettingsSection.engine.title == "Speech model")
    }
}

@Suite("Settings compatibility with 1.0.x")
struct SettingsCompatibilityTests {
    @Test("Line numbers are optional: absent means on, and 1.0.0 still reads files that set it")
    func lineNumbersRoundTrip() throws {
        var preferences = AppPreferences.default
        #expect(preferences.appearance.showsLineNumbers == nil)
        #expect(preferences.appearance.lineNumbersVisible)
        preferences.appearance.lineNumbersVisible = false
        let data = try JSONEncoder().encode(preferences)
        let current = try JSONDecoder().decode(AppPreferences.self, from: data)
        #expect(current.appearance.lineNumbersVisible == false)
        let released = try JSONDecoder().decode(Released100Preferences.Preferences.self, from: data)
        #expect(released.appearance.accent.rawValue == preferences.appearance.accent.rawValue)

        let old = try JSONDecoder().decode(AppPreferences.Appearance.self, from: Data(#"{"mode":"light"}"#.utf8))
        #expect(old.showsLineNumbers == nil)
        #expect(old.lineNumbersVisible)
    }

    @Test("The recording choices are saved in the recording section, and 1.0.0 still reads the file")
    func recordingChoicesAreSaved() throws {
        var preferences = AppPreferences.default
        preferences.inputDeviceID = "usb"
        preferences.afterInserting = .nothing
        preferences.recording.pasteLastShortcut = "control+option+9"
        #expect(preferences.recording.inputDeviceID == "usb")
        #expect(preferences.recording.afterInserting == "nothing")
        #expect(preferences.recording.pasteLastGlobalShortcut == GlobalShortcut(keyCode: 9, modifiers: [.control, .option]))
        let data = try JSONEncoder().encode(preferences)
        _ = try JSONDecoder().decode(Released100Preferences.Preferences.self, from: data)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
        #expect(decoded.inputDeviceID == "usb")
        #expect(decoded.afterInserting == .nothing)
        #expect(decoded.recording.pasteLastGlobalShortcut == GlobalShortcut(keyCode: 9, modifiers: [.control, .option]))
    }

    @Test("Insertion behaviour choices keep the raw values the saved field will use")
    func choiceRawValues() {
        #expect(AfterInsertingChoice.allCases.map(\.rawValue) == ["matters", "always", "nothing"])
        var preferences = AppPreferences.default
        preferences.afterInserting = .matters
        #expect(preferences.recording.afterInserting == nil)
    }
}
