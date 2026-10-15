import AppKit
import Foundation
@testable import Steno
@testable import StenoKit

/// A session coordinator for window tests. Capture starts at once, and each finished dictation is
/// saved to History with the words and outcome the test scripted, as the real coordinator saves
/// it, so the controller's own refresh brings it to the window.
actor ScriptedCoordinator: DictationSessionCoordinating {
    struct Outcome: Sendable {
        var text: String
        var status: InsertionStatus
        var copyReason: InsertionCopyReason?
        var bundleID = "com.apple.mail"
    }

    private let history: HistoryStore
    private var outcome: Outcome
    private var held = false
    private var failure: String?
    private(set) var events: [String] = []

    init(history: HistoryStore, outcome: Outcome) {
        self.history = history
        self.outcome = outcome
    }

    func script(_ outcome: Outcome) { self.outcome = outcome }
    /// Keeps the next transcription waiting until `release()`, so a test can see Transcribing.
    func hold() { held = true }
    func release() { held = false }
    func count(_ event: String) -> Int { events.filter { $0 == event }.count }
    /// Makes the next transcription throw with `message`, as a runtime failure does.
    func failNextTranscription(_ message: String) { failure = message }

    struct TranscriptionFailure: LocalizedError {
        let errorDescription: String?
    }

    func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        events.append("start")
        return SessionID()
    }

    func endPressToTalkCapture(sessionID: SessionID) async throws {
        events.append("stop")
    }

    func completePressToTalk(sessionID: SessionID, languageHints: [String]) async throws -> InsertResult {
        try await complete(copyingBecause: nil)
    }

    func completePressToTalk(sessionID: SessionID, languageHints: [String],
                             copyingBecause copyReason: InsertionCopyReason?) async throws -> InsertResult {
        try await complete(copyingBecause: copyReason)
    }

    private func complete(copyingBecause reason: InsertionCopyReason?) async throws -> InsertResult {
        events.append("transcribe")
        // Marks the end of the transcription however it ends, so a test can wait for it.
        defer { events.append("returned") }
        while held { try await Task.sleep(for: .milliseconds(5)) }
        if let failure {
            self.failure = nil
            events.append("failed")
            throw TranscriptionFailure(errorDescription: failure)
        }
        var outcome = outcome
        if let reason, outcome.status == .inserted {
            outcome.status = .copiedOnly
            outcome.copyReason = reason
        }
        if outcome.status != .noSpeech {
            var entry = TranscriptEntry(appBundleID: outcome.bundleID, rawText: outcome.text, cleanText: outcome.text,
                                        durationMS: 4_000, audioURL: nil, insertionStatus: outcome.status)
            if let copyReason = outcome.copyReason {
                entry.record = DictationRecord(copyReason: copyReason.rawValue)
            }
            try await history.append(entry: entry)
        }
        events.append("finished")
        var result = InsertResult(status: outcome.status, method: outcome.status == .inserted ? .direct : .none,
                                  insertedText: outcome.status == .noSpeech ? "" : outcome.text)
        result.copyReason = outcome.copyReason
        return result
    }

    func cancel(sessionID: SessionID) async {
        events.append("cancel")
    }

    func insertText(_ text: String, into target: AppContext) async -> InsertResult {
        events.append("insert: \(text)")
        return InsertResult(status: .inserted, method: .direct, insertedText: text)
    }

    func setHandsFreeEnabled(_ enabled: Bool) async {}
}

/// A real controller with its own History in a temporary folder, a scripted coordinator, an
/// offscreen overlay and every permission granted, so a window test can dictate through Today's
/// and the menu's own controls.
@MainActor
struct WindowDictation {
    let controller: DictationController
    /// The shortcuts, as the keys pressed in another app reach the controller.
    let hotkey: TransitionHotkey
    let coordinator: ScriptedCoordinator
    let history: HistoryStore
    let clipboard: MemoryClipboardService
    let overlay: WaveformOverlayPresenter
    let directory: URL

    static func make(entries: [TranscriptEntry] = [],
                     outcome: ScriptedCoordinator.Outcome = .init(text: "Book the room for Friday at ten.", status: .inserted),
                     permissions: PermissionStatusSnapshot = .init(microphone: .granted, accessibility: .granted, inputMonitoring: .granted))
        async throws -> WindowDictation {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StenoWindowDictation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clipboard = MemoryClipboardService()
        let history = HistoryStore(storageURL: directory.appendingPathComponent("history.json"))
        for entry in entries.reversed() { try await history.append(entry: entry) }
        let coordinator = ScriptedCoordinator(history: history, outcome: outcome)
        let overlay = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        overlay.hostedEvidencePrepareOffscreen()
        let hotkey = TransitionHotkey()
        let controller = makeTestDictationController(
            hotkey: hotkey, overlay: overlay, coordinator: coordinator, historyStore: history,
            legacyHistoryURL: directory.appendingPathComponent("legacy.json"), clipboardService: clipboard,
            permissionStatusReader: { permissions })
        controller.microphoneAccessProvider = { permissions.microphone }
        controller.microphonePermissionStatus = permissions.microphone
        controller.accessibilityPermissionStatus = permissions.accessibility
        controller.inputMonitoringPermissionStatus = permissions.inputMonitoring
        await controller.refreshHistory()
        return WindowDictation(controller: controller, hotkey: hotkey, coordinator: coordinator, history: history, clipboard: clipboard,
                               overlay: overlay, directory: directory)
    }

    func close() async {
        await controller.teardownAndWait()
        overlay.hide()
        try? FileManager.default.removeItem(at: directory)
    }
}
