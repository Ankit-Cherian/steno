import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Steno
import StenoKit

@MainActor
@Test("A transcript inserted before History fails is reported as inserted and stays copyable")
func historyFailureAfterInsertionIsNotATranscriptionFailure() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoStorageRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let coordinator = HistoryFailureCoordinator()
    let controller = makeTestDictationController(
        hotkey: StorageRecoveryTestHotkeyService(),
        coordinator: coordinator,
        historyStore: HistoryStore(
            storageURL: directory.appendingPathComponent("history.json"),
            clipboardService: MemoryClipboardService()
        )
    )
    defer { controller.teardown() }

    controller.pressToTalkStart()
    #expect(await waitForStorageRecoveryCondition { controller.isRecording })
    controller.pressToTalkStop()
    #expect(await waitForStorageRecoveryCondition { controller.storageNotice != nil })

    #expect(controller.status.hasPrefix("Transcript inserted."))
    #expect(controller.status.contains("couldn't be saved to History"))
    #expect(!controller.status.contains("Transcription failed"))
    #expect(controller.lastError.isEmpty)
    #expect(controller.lastTranscript == "Meeting notes are ready")
    #expect(controller.storageNotice?.recoverableText == "Meeting notes are ready")
    #expect(await coordinator.completionCount == 1)
    #expect(await waitForStorageRecoveryCondition { controller.recordingLifecycleState == .idle })
}

private actor HistoryFailureCoordinator: DictationSessionCoordinating {
    private(set) var completionCount = 0

    func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        SessionID()
    }

    func endPressToTalkCapture(sessionID: SessionID) async throws {}

    /// Mirrors `SessionCoordinator` after a committed insertion whose History
    /// write failed.
    func completePressToTalk(sessionID: SessionID, languageHints: [String]) async throws -> InsertResult {
        completionCount += 1
        var result = InsertResult(status: .inserted, method: .direct, insertedText: "Meeting notes are ready")
        result.historyWarning = HistoryStoreError.persistenceFailed.localizedDescription
        return result
    }

    func cancel(sessionID: SessionID) async {}

    func setHandsFreeEnabled(_ enabled: Bool) async {}
}

@MainActor
final class StorageRecoveryTestHotkeyService: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16?

    func start() {}
    func stop() {}
}

@MainActor
func waitForStorageRecoveryCondition(
    attempts: Int = 400,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

@MainActor
@Test("A Settings save that can't be written never reports success and keeps the draft unsaved")
func failedSettingsSaveKeepsDraftUnsaved() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoSettingsSaveFailure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let storageURL = directory.appendingPathComponent("preferences.json")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    let store = AppPreferencesStore(storageURL: storageURL)
    await store.save(.default)
    let savedBytes = try Data(contentsOf: storageURL)

    let controller = makeTestDictationController(
        hotkey: StorageRecoveryTestHotkeyService(),
        preferencesStore: store
    )
    defer { controller.teardown() }
    let saved = controller.preferences
    var draft = saved
    draft.snippets = [Snippet(trigger: "sig", expansion: "Best regards")]
    var draftState = SettingsDraftState(saved: saved)
    draftState.edit(draft)

    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    let save = controller.applySettingsDraft(preferences: draft)
    draftState.reload(controller.preferences)
    #expect(await save.value == false)
    draftState.restoreUnsaved(draft, saved: controller.preferences)
    draftState.reconcile(controller.preferences)

    #expect(controller.status == "Settings couldn't be saved.")
    #expect(!controller.settingsSaveError.isEmpty)
    #expect(controller.preferences == saved)
    #expect(draftState.preferences == draft)
    #expect(draftState.preferences != controller.preferences, "Save and Discard stay available")
    #expect(!draftState.hasConflictingUpdate)
    #expect(try Data(contentsOf: storageURL) == savedBytes)

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    let retry = controller.applySettingsDraft(preferences: draftState.preferences)
    #expect(await retry.value)
    #expect(controller.settingsSaveError.isEmpty)
    #expect(await AppPreferencesStore(storageURL: storageURL).load().snippets.map(\.trigger) == ["sig"])
}

@Suite("Failed Settings save draft recovery")
struct FailedSettingsSaveDraftTests {
    @Test("Restoring unsaved edits keeps the draft dirty whichever update arrives first", arguments: [true, false])
    func restoreSurvivesUpdateOrder(revertArrivesFirst: Bool) {
        let saved = AppPreferences.default
        var submitted = saved
        submitted.media.pauseDuringHandsFree.toggle()
        var state = SettingsDraftState(saved: saved)
        state.edit(submitted)
        state.reload(submitted)

        if revertArrivesFirst {
            state.reconcile(saved)
            state.restoreUnsaved(submitted, saved: saved)
        } else {
            state.restoreUnsaved(submitted, saved: saved)
            state.reconcile(saved)
        }
        #expect(state.preferences == submitted)
        #expect(state.savedPreferences == saved)
        #expect(!state.hasConflictingUpdate)
    }
}

@MainActor
@Test("Storage notices and a failed Settings save render in the production views")
func storageNoticeRenders() async throws {
    AppFontRegistry.registerIfNeeded()
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STENO_UI_RENDER_OUTPUT"]
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("StenoUIRendering").path)
        .appendingPathComponent("storage-recovery", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let renderer = AppRenderingTests()
    let notices = [
        ("history-kept", StorageRecoveryNotice(
            message: "3 History entries couldn't be read and are hidden. Steno kept a copy of the original file.",
            fileURL: URL(fileURLWithPath: "/tmp/transcript-history.original-20260929T120000Z.json")
        )),
        ("unsaved-transcript", StorageRecoveryNotice(
            message: "This transcript was inserted but couldn't be saved to History.",
            fileURL: nil,
            recoverableText: "Meeting notes are ready"
        )),
    ]
    for appearance in [ColorScheme.light, .dark] {
        for (name, notice) in notices {
            for (sizeName, size, accessibility) in [
                ("minimum-accessible", CGSize(width: StenoDesign.windowMinWidth, height: StenoDesign.windowMinHeight), true),
                ("default", CGSize(width: StenoDesign.windowIdealWidth, height: StenoDesign.windowIdealHeight), false),
            ] {
                let controller = IsolatedAppPreview.makeController(populated: true)
                controller.preferences.appearance.mode = appearance == .light ? .light : .dark
                controller.storageNotice = notice
                let data = try await renderer.render(ContentView(), controller: controller,
                    appearance: appearance, size: size, accessibility: accessibility)
                try data.write(to: root.appendingPathComponent("\(name)-\(appearance)-\(sizeName).png"))
                await controller.teardownAndWait()
            }
        }

        let controller = IsolatedAppPreview.makeController(populated: false)
        controller.preferences.appearance.mode = appearance == .light ? .light : .dark
        controller.settingsSaveError = AppPreferencesStoreError.writeFailed.localizedDescription
        var draftState = SettingsDraftState(saved: controller.preferences)
        var edited = controller.preferences
        edited.hotkeys.optionPressToTalkEnabled.toggle()
        draftState.edit(edited)
        let theme = StenoDesign.theme(for: controller.preferences)
        let data = try await renderer.render(SettingsView(previewDraftState: draftState)
            .foregroundStyle(theme.text).background(theme.ink0),
            controller: controller, appearance: appearance,
            size: CGSize(width: StenoDesign.windowMinWidth, height: StenoDesign.windowMinHeight), accessibility: true)
        try data.write(to: root.appendingPathComponent("settings-save-failed-\(appearance)-minimum-accessible.png"))
        await controller.teardownAndWait()
    }
}
