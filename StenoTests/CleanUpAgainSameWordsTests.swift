import Foundation
import StenoKit
import Testing
@testable import Steno

@MainActor
private final class SameWordsHotkey: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16?

    func start() {}
    func stop() {}
}

/// Clean Up Again on a dictation whose live cleanup already gives the same words.
@Suite("Clean Up Again with the same words", .serialized)
@MainActor
struct CleanUpAgainSameWordsTests {
    private static let sameWords = "Cleanup gave the same words."
    private static let rerun = "Cleanup re-run with current rules."

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoSameWords-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Clean Up Again that gives back the live text keeps the Fix a Word edit, writes nothing and says so")
    func cleanUpAgainWithTheSameWordsKeepsAWordFix() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyURL = directory.appendingPathComponent("history.json")
        let history = HistoryStore(storageURL: historyURL)
        let live = TranscriptEntry(
            appBundleID: "com.apple.Notes", rawText: "ship the gizmo build today",
            cleanText: "Ship the gizmo build today", audioURL: nil, insertionStatus: .inserted
        )
        try await history.append(entry: live)
        let controller = makeTestDictationController(
            hotkey: SameWordsHotkey(),
            historyStore: history,
            legacyHistoryURL: directory.appendingPathComponent("missing-legacy.json")
        )
        defer { controller.teardown() }
        await controller.refreshHistory()

        func stored() async -> TranscriptEntry? {
            await history.recent(limit: 10).first { $0.id == live.id }
        }
        func cleanUpAgain() async -> Bool {
            controller.status = ""
            controller.retryCleanup(for: live)
            return await eventuallyOnMain {
                controller.status == Self.sameWords || controller.status == Self.rerun
                    || controller.status == "Cleanup re-run failed"
            }
        }

        // Before any fix, Clean Up Again gives the live text back and changes nothing.
        try #require(await cleanUpAgain())
        #expect(controller.status == Self.sameWords, "status is \(controller.status): \(controller.lastError)")
        let beforeFix = try #require(await stored())
        try #require(beforeFix.cleanText == "Ship the gizmo build today")
        try #require(beforeFix.originalCleanText == nil)

        // The person fixes one word in this dictation.
        _ = try await controller.applyWordFix(
            entryID: live.id, original: "gizmo", occurrence: 0, replacement: "Gizmo", appliesToFuture: false
        )
        let fixedEntry = try #require(await stored())
        try #require(fixedEntry.cleanText == "Ship the Gizmo build today")
        try #require(fixedEntry.fixes?.count == 1)
        let fileBefore = try Data(contentsOf: historyURL)

        // Clean Up Again with unchanged settings: the cleanup engine returns the live text.
        try #require(await cleanUpAgain())
        #expect(controller.status == Self.sameWords, "status is \(controller.status): \(controller.lastError)")

        let after = try #require(await stored())
        #expect(after.cleanText == "Ship the Gizmo build today", "the reader now says \(after.cleanText)")
        #expect(after.fixes?.count == 1, "fixes are \(String(describing: after.fixes))")
        #expect(after.originalCleanText == nil)
        #expect(try Data(contentsOf: historyURL) == fileBefore, "the history file was rewritten")
    }
}
