import Foundation
import Testing
@testable import StenoKit

@Test("HistoryStore supports append, search, and paste-last recovery")
func historyStoreRecoveryFlow() async throws {
    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("history-tests", isDirectory: true)
        .appendingPathComponent("history-\(UUID().uuidString).json")

    let clipboard = MemoryClipboardService()
    let store = HistoryStore(storageURL: tempURL, clipboardService: clipboard)

    let first = TranscriptEntry(
        appBundleID: "com.apple.Notes",
        rawText: "um first note",
        cleanText: "First note",
        audioURL: nil,
        insertionStatus: .inserted
    )
    let second = TranscriptEntry(
        appBundleID: "com.todesktop.230313mzl4w4u92",
        rawText: "second entry",
        cleanText: "Second entry",
        audioURL: nil,
        insertionStatus: .copiedOnly
    )

    try await store.append(entry: first)
    try await store.append(entry: second)

    let recent = await store.recent(limit: 2)
    #expect(recent.count == 2)
    #expect(recent[0].id == second.id)

    let search = await store.search(query: "notes")
    #expect(search.count == 1)
    #expect(search[0].id == first.id)

    let pasted = try await store.pasteLast()
    #expect(pasted?.id == second.id)

    let clipboardValue = await clipboard.latestValue
    #expect(clipboardValue == "Second entry")
}
