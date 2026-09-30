import AppKit
import Foundation
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
