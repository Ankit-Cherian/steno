import Combine
import Foundation
@testable import StenoKit
import Testing
@testable import Steno

/// What the controller publishes for the Library's recording plate.
@MainActor
@Suite("Recording plate inputs in the controller")
struct GroveRecordingPlateControllerTests {
    private func makeController(history: HistoryStore? = nil, clipboard: MemoryClipboardService = MemoryClipboardService()) -> DictationController {
        makeTestDictationController(
            hotkey: StatusReportingHotkeyService(),
            overlay: makeShortcutTestPresenter(),
            coordinator: CaptureTestCoordinator(
                result: InsertResult(status: .inserted, method: .accessibility, insertedText: "Words")),
            historyStore: history,
            clipboardService: clipboard)
    }

    private func snapshot(stable: String, tail: String) -> LiveTranscriptionSnapshot {
        let session = LiveTranscriptionSession(sessionID: UUID(), controllerGeneration: UUID(), runtimeGeneration: 1, runtimeIdentity: .pending)
        return LiveTranscriptionSnapshot(session: session, stablePrefix: stable, revisableTail: tail,
                                         lastAcceptedRevision: 1, decodedAudioWatermark: 1_600)
    }

    @Test("The destination app is published while recording and cleared when it ends")
    func targetApp() async {
        let controller = makeController()
        defer { controller.teardown() }
        #expect(controller.recordingTargetAppName == nil)
        controller.toggleHandsFree()
        #expect(await waitForShortcutCondition { controller.isRecording })
        #expect(controller.recordingTargetAppName == "Test Editor")
        controller.cancelActiveRecording()
        #expect(controller.recordingTargetAppName == nil)
    }

    @Test("Live words publish only when they change, on their own feed, and end with the recording")
    func liveWords() async {
        let controller = makeController()
        defer { controller.teardown() }
        var published: [DictationController.LiveWords?] = []
        let token = controller.liveWordsFeed.$words.dropFirst().sink { published.append($0) }
        defer { token.cancel() }

        controller.toggleHandsFree()
        #expect(await waitForShortcutCondition { controller.isRecording })
        // Every view that observes the controller redraws when it changes; live words must not.
        var controllerChanges = 0
        let watcher = controller.objectWillChange.sink { _ in controllerChanges += 1 }
        controller.publishLiveWords(snapshot(stable: "Move the meeting ", tail: "to Fri"))
        controller.publishLiveWords(snapshot(stable: "Move the meeting ", tail: "to Fri"))
        controller.publishLiveWords(snapshot(stable: "Move the meeting ", tail: "to Friday"))
        watcher.cancel()
        #expect(controllerChanges == 0, "live words notified the controller's observers \(controllerChanges) times")
        #expect(published == [
            DictationController.LiveWords(stable: "Move the meeting ", tail: "to Fri"),
            DictationController.LiveWords(stable: "Move the meeting ", tail: "to Friday")
        ])
        controller.cancelActiveRecording()
        #expect(controller.liveWords == nil)
        #expect(published.last == .some(nil))
    }

    @Test("Copy reports whether the clipboard took the words")
    func copyCompletion() async {
        let clipboard = MemoryClipboardService()
        let controller = makeController(clipboard: clipboard)
        defer { controller.teardown() }
        let entry = TranscriptEntry(appBundleID: "com.example.steno-test-editor", rawText: "raw", cleanText: "Clean words",
                                    audioURL: nil, insertionStatus: .inserted)
        var results: [Bool] = []
        controller.pasteEntry(entry) { results.append($0) }
        #expect(await waitForShortcutCondition { !results.isEmpty })
        #expect(results == [true])
        #expect(await clipboard.latestValue == "Clean words")
    }

    @Test("Delete reports that the dictation is gone")
    func deleteCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StenoGroveDelete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clipboard = MemoryClipboardService()
        let history = HistoryStore(storageURL: directory.appendingPathComponent("history.json"))
        let controller = makeController(history: history, clipboard: clipboard)
        defer { controller.teardown() }
        let entry = TranscriptEntry(appBundleID: "com.example.steno-test-editor", rawText: "raw", cleanText: "Clean",
                                    audioURL: nil, insertionStatus: .inserted)
        try await history.append(entry: entry)
        await controller.refreshHistory()
        var results: [Bool] = []
        controller.deleteEntry(entry) { results.append($0) }
        #expect(await waitForShortcutCondition { !results.isEmpty })
        #expect(results == [true])
        #expect(controller.recentEntries.isEmpty)
    }
}
