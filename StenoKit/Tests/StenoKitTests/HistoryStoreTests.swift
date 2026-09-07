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
        durationMS: 14_000,
        audioURL: nil,
        insertionStatus: .inserted
    )
    let second = TranscriptEntry(
        appBundleID: "com.todesktop.230313mzl4w4u92",
        rawText: "second entry",
        cleanText: "Second entry",
        durationMS: 28_000,
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
    #expect(recent[0].durationMS == 28_000)
}

@Test("HistoryStore retains the newest 1,000 entries across append and reload")
func historyStoreDefaultCapacity() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("history-capacity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storageURL = directory.appendingPathComponent("history.json")
    let existing = (0..<999).map { index in
        TranscriptEntry(
            appBundleID: "com.example.editor",
            rawText: "Existing entry \(index)",
            cleanText: "Existing entry \(index)",
            audioURL: nil,
            insertionStatus: .inserted
        )
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(existing).write(to: storageURL, options: .atomic)

    let store = HistoryStore(storageURL: storageURL, clipboardService: MemoryClipboardService())
    let thousandth = TranscriptEntry(
        appBundleID: "com.example.editor",
        rawText: "Entry one thousand",
        cleanText: "Entry one thousand",
        audioURL: nil,
        insertionStatus: .inserted
    )
    try await store.append(entry: thousandth)
    let atCapacity = await store.recent(limit: 1_001)
    try #require(atCapacity.count == 1_000)
    #expect(atCapacity.map(\.id) == [thousandth.id] + existing.map(\.id))

    let newest = TranscriptEntry(
        appBundleID: "com.example.editor",
        rawText: "Newest entry",
        cleanText: "Newest entry",
        audioURL: nil,
        insertionStatus: .inserted
    )
    try await store.append(entry: newest)
    let reloaded = HistoryStore(storageURL: storageURL, clipboardService: MemoryClipboardService())
    let retained = await reloaded.recent(limit: 1_001)
    #expect(retained.count == 1_000)
    #expect(retained.map(\.id) == [newest.id, thousandth.id] + existing.dropLast().map(\.id))
}
