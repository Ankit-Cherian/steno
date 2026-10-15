import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

/// The strip shown when History can't save a dictation offers to copy it. A dictation that was
/// meant for a secure field is copied concealed there too, as Copy Last Dictation does.
@MainActor
@Suite("StorageNoticeCopyConcealment", .serialized)
struct StorageNoticeCopyConcealmentTests {
    private static let secretText = "Hunter two"

    @Test("The History-save-failure strip's Copy Dictation copies a secure-field dictation concealed")
    func recoveryStripCopyDictationKeepsASecureFieldDictationConcealed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoStorageNoticeCopy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clipboard = WriteMarkRecordingClipboard()
        let history = HistoryStore(storageURL: directory.appendingPathComponent("history.json"))
        let controller = DictationController(
            hotkey: TranscriptionCancelHotkey(),
            clipboardService: clipboard,
            overlay: WaveformOverlayPresenter(observeAccessibilityChanges: false),
            mediaInterruption: IsolatedTestMediaService(),
            preferencesStore: AppPreferencesStore(storageURL: directory.appendingPathComponent("preferences.json")),
            coordinator: SecureFieldUnsavedCoordinator(),
            runtimeRebuildOverride: { nil },
            overlayDismissDelay: {},
            historyStore: history,
            usageAnalyticsStore: UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json")),
            legacyHistoryURL: directory.appendingPathComponent("legacy.json"),
            systemIntegrationsEnabled: false,
            appContextProvider: { AppContext(bundleIdentifier: "com.example.steno-test-editor", appName: "Test Editor") },
            targetDisplayPointProvider: { CGPoint(x: 400, y: 300) }
        )

        controller.pressToTalkStart()
        try #require(await concealmentEventually { @MainActor in controller.isRecording })
        controller.pressToTalkStop()
        try #require(await concealmentEventually { @MainActor in controller.storageNotice != nil })
        try #require(await concealmentEventually { @MainActor in controller.recordingLifecycleState == .idle })
        try #require(controller.storageNotice?.recoverableText == Self.secretText)
        try #require(await clipboard.writeCount() == 0)

        // Control: Copy Last Dictation for the same unsaved dictation is concealed.
        controller.copyLastDictation()
        try #require(await concealmentEventually { await clipboard.writeCount() == 1 })
        #expect(await clipboard.concealedValues() == [Self.secretText], "control: Copy Last Dictation is concealed")
        #expect(await clipboard.plainValues().isEmpty)

        // The strip's Copy Dictation button.
        controller.copyStorageNoticeText()
        try #require(await concealmentEventually { await clipboard.writeCount() == 2 })
        let plainFromStrip = await clipboard.plainValues()
        let concealedAfterStrip = await clipboard.concealedValues()
        #expect(plainFromStrip.isEmpty, "plain writes from the strip: \(plainFromStrip)")
        #expect(concealedAfterStrip == [Self.secretText, Self.secretText], "concealed writes: \(concealedAfterStrip)")
        await controller.teardownAndWait()
    }
}

// MARK: - Support

/// Completes a dictation into a password field: the insertion was refused and the text copied
/// concealed, but History could not save it.
private actor SecureFieldUnsavedCoordinator: DictationSessionCoordinating {
    func startPressToTalk(appContext: AppContext) async throws -> SessionID { SessionID() }
    func endPressToTalkCapture(sessionID: SessionID) async throws {}
    func completePressToTalk(sessionID: SessionID, languageHints: [String]) async throws -> InsertResult {
        var result = InsertResult(
            status: .copiedOnly,
            method: .clipboardPaste,
            insertedText: "Hunter two",
            errorMessage: "Secure text field\u{2014}final text copied instead of typed.",
            copyReason: .secureField,
            copyIsConcealed: true
        )
        result.historyWarning = HistoryStoreError.persistenceFailed.localizedDescription
        return result
    }
    func insertText(_ text: String, into target: AppContext) async -> InsertResult {
        InsertResult(status: .inserted, method: .direct, insertedText: text)
    }
    func cancel(sessionID: SessionID) async {}
    func setHandsFreeEnabled(_ enabled: Bool) async {}
}
