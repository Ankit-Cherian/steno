import Foundation
import Testing
@testable import StenoKit

@Suite("Deleting one History entry")
struct HistoryStoreDeleteTests {
    private static func entry(_ text: String) -> TranscriptEntry {
        TranscriptEntry(
            appBundleID: "com.example.Editor",
            rawText: text,
            cleanText: text,
            durationMS: 2_000,
            audioURL: nil,
            insertionStatus: .inserted
        )
    }

    @Test("A deleted entry's text is in neither the History file nor its previous copy")
    func deleteLeavesNoTextInPreviousCopy() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryDelete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("transcript-history.json")
        let store = HistoryStore(storageURL: url, clipboardService: MemoryClipboardService())

        let deleted = Self.entry("Fictional deleted note")
        let kept = Self.entry("Fictional kept note")
        try await store.append(entry: deleted)
        try await store.append(entry: kept)
        try await store.append(entry: Self.entry("Fictional newest note"))
        let previousURL = StorageFilePreservation.previousCopyURL(for: url)
        #expect(try Data(contentsOf: previousURL).range(of: Data("Fictional deleted note".utf8)) != nil)

        try await store.delete(entryID: deleted.id)

        for file in [url, previousURL] {
            let contents = try Data(contentsOf: file)
            #expect(contents.range(of: Data("Fictional deleted note".utf8)) == nil, "\(file.lastPathComponent) still holds the deleted text")
            #expect(contents.range(of: Data("Fictional kept note".utf8)) != nil, "\(file.lastPathComponent) lost a kept entry")
        }
        let reopened = HistoryStore(storageURL: url, clipboardService: MemoryClipboardService())
        #expect(await reopened.recent(limit: 10).map(\.id).contains(kept.id))
    }

    @Test("Saves after a delete keep the previous copy as before")
    func appendAfterDeleteKeepsReplacedFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryDelete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("transcript-history.json")
        let store = HistoryStore(storageURL: url, clipboardService: MemoryClipboardService())

        let deleted = Self.entry("Fictional deleted note")
        try await store.append(entry: deleted)
        try await store.append(entry: Self.entry("Fictional kept note"))
        try await store.delete(entryID: deleted.id)
        let beforeAppend = try Data(contentsOf: url)

        try await store.append(entry: Self.entry("Fictional later note"))

        #expect(try Data(contentsOf: StorageFilePreservation.previousCopyURL(for: url)) == beforeAppend)
    }
}
