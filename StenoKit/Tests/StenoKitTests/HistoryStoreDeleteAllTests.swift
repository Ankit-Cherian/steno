import Foundation
import Testing
@testable import StenoKit

@Suite("Deleting all History")
struct HistoryStoreDeleteAllTests {
    private static func entry(_ text: String, daysAgo: Double) -> TranscriptEntry {
        TranscriptEntry(
            createdAt: Date().addingTimeInterval(-daysAgo * 86_400),
            appBundleID: "com.example.Editor",
            rawText: text,
            cleanText: text,
            durationMS: 2_000,
            audioURL: nil,
            insertionStatus: .inserted
        )
    }

    @Test("Delete all removes every transcript, including the kept previous copy")
    func deleteAllRemovesEveryTranscript() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryDeleteAll-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("transcript-history.json")
        let store = HistoryStore(storageURL: url, clipboardService: MemoryClipboardService())

        for (index, age) in [120.0, 45, 2].enumerated() {
            try await store.append(entry: Self.entry("Fictional note \(index)", daysAgo: age))
        }
        let previousURL = StorageFilePreservation.previousCopyURL(for: url)
        #expect(FileManager.default.fileExists(atPath: previousURL.path))

        try await store.deleteAll()

        #expect(await store.recent(limit: 1_000).isEmpty)
        let reopened = HistoryStore(storageURL: url, clipboardService: MemoryClipboardService())
        #expect(await reopened.recent(limit: 1_000).isEmpty)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode([TranscriptEntry].self, from: Data(contentsOf: url)).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: previousURL.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") && $0 != url.lastPathComponent }
        #expect(leftovers.isEmpty)
    }

    @Test("History keeps working after everything was deleted")
    func appendAfterDeleteAll() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryDeleteAll-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("transcript-history.json")
        let store = HistoryStore(storageURL: url, clipboardService: MemoryClipboardService())

        try await store.deleteAll()
        let kept = Self.entry("Fictional follow-up", daysAgo: 0)
        try await store.append(entry: kept)

        #expect(await store.recent(limit: 10).map(\.id) == [kept.id])
    }
}
