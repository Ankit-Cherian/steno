import Foundation
import Testing
@testable import Steno
import StenoKit

@MainActor
private final class RerunTestHotkeyService: HotkeyService {
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
private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

@MainActor
@Test("Run cleanup again matches live dictation in an IDE, keeps the original, and restores it")
func controllerRerunAndRestore() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoRerunTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let historyStore = HistoryStore(
        storageURL: directory.appendingPathComponent("history.json"),
        clipboardService: MemoryClipboardService()
    )
    // What live dictation saved in VS Code (IDE profile: no sentence capitalization), in Notes
    // under older rules, and for a spoken lowercase directive.
    let vsCode = TranscriptEntry(
        appBundleID: "com.microsoft.VSCode",
        rawText: "npm install stenoh",
        cleanText: "npm install Steno",
        audioURL: nil,
        insertionStatus: .inserted
    )
    let notes = TranscriptEntry(
        appBundleID: "com.apple.Notes",
        rawText: "open stenoh now",
        cleanText: "open stenoh now",
        audioURL: nil,
        insertionStatus: .inserted
    )
    let directive = TranscriptEntry(
        appBundleID: "com.apple.Notes",
        rawText: "lowercase hello there",
        cleanText: "hello there",
        audioURL: nil,
        insertionStatus: .inserted
    )
    for entry in [vsCode, notes, directive] {
        try await historyStore.append(entry: entry)
    }

    let controller = makeTestDictationController(
        hotkey: RerunTestHotkeyService(),
        historyStore: historyStore,
        legacyHistoryURL: directory.appendingPathComponent("missing-legacy.json")
    )
    defer { controller.teardown() }

    func stored(_ entry: TranscriptEntry) async -> TranscriptEntry? {
        await historyStore.recent(limit: 10).first { $0.id == entry.id }
    }

    controller.status = ""
    controller.retryCleanup(for: vsCode)
    #expect(await waitUntil { controller.status == "Cleanup re-run with current rules." })
    #expect(await stored(vsCode)?.originalCleanText == nil)
    #expect(await stored(vsCode)?.cleanText == "npm install Steno")

    controller.status = ""
    controller.retryCleanup(for: directive)
    #expect(await waitUntil { controller.status == "Cleanup re-run with current rules." })
    #expect(await stored(directive)?.cleanText == "hello there")

    controller.status = ""
    controller.retryCleanup(for: notes)
    #expect(await waitUntil { await stored(notes)?.originalCleanText != nil })
    #expect(await stored(notes)?.cleanText == "Open Steno now")
    #expect(await stored(notes)?.originalCleanText == "open stenoh now")

    let rerun = try #require(await stored(notes))
    controller.restoreOriginalCleanup(for: rerun)
    #expect(await waitUntil { await stored(notes)?.originalCleanText == nil })
    #expect(await stored(notes)?.cleanText == "open stenoh now")
    #expect(controller.lastError.isEmpty)
}
