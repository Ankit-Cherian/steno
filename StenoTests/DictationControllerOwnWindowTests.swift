import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

/// Dictation started from Steno's own window, with no text field focused there.
@Suite(.serialized)
@MainActor
struct DictationControllerOwnWindowTests {
    @Test("Steno's own window with no text field focused reports the transcript as copied, not inserted")
    func ownWindowWithoutTextFocusReportsCopied() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoOwnWindow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = TranscriptionCancelCapture(directory: directory)
        let typing = TranscriptionCancelTransport()
        let clipboard = MemoryClipboardService()
        let history = HistoryStore(
            storageURL: directory.appendingPathComponent("history.json"),
            clipboardService: MemoryClipboardService()
        )
        // The test controller dictates into this bundle; here it stands for
        // Steno itself, with nothing focused that can take text.
        let ownApp = OwnAppTextFocus(
            ownBundleIdentifier: "com.example.steno-test-editor",
            focusAcceptsText: { false }
        )
        let coordinator = SessionCoordinator(
            captureService: capture,
            transcriptionEngine: FixedTextEngine(),
            cleanupEngine: RuleBasedCleanupEngine(),
            insertionService: InsertionService(
                transports: [typing, ClipboardInsertionTransport(clipboard: clipboard)],
                ownAppTextFocus: ownApp
            ),
            historyStore: history,
            lexiconService: PersonalLexiconService(entries: []),
            styleProfileService: StyleProfileService(),
            editorTargetCapture: { _ in .failure(.unsupportedElement) }
        )
        let presenter = makeShortcutTestPresenter()
        let controller = makeTestDictationController(
            hotkey: TranscriptionCancelHotkey(),
            overlay: presenter,
            coordinator: coordinator,
            historyStore: history,
            legacyHistoryURL: directory.appendingPathComponent("legacy.json")
        )
        defer { controller.teardown() }

        controller.pressToTalkStart()
        try #require(await cancelTestEventually { await capture.startedCount() == 1 })
        controller.pressToTalkStop()
        try #require(await waitForShortcutCondition(attempts: 1_000) {
            controller.recordingLifecycleState == .idle && !controller.lastTranscript.isEmpty
        })

        #expect(await typing.texts().isEmpty)
        #expect(await clipboard.latestValue == controller.lastTranscript)
        #expect(controller.status == "Transcript copied to clipboard. Paste with Cmd+V.")
        #expect(controller.lastError.isEmpty)
        #expect(presenter.hostedEvidenceShownStates().last == .copiedOnly)
        #expect(!presenter.hostedEvidenceShownStates().contains(.inserted))
        let entry = try #require(await history.recent(limit: 1).first)
        #expect(entry.insertionStatus == .copiedOnly)
        #expect(entry.pasteAttempted == nil)

        await coordinator.shutdown()
    }
}
