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

    @Test("A dictation after Delete all leaves no deleted transcript in the file or its previous copy")
    func dictationAfterDeleteAllKeepsNoDeletedText() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryDeleteAll-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("transcript-history.json")
        let store = HistoryStore(storageURL: url, clipboardService: MemoryClipboardService())

        let deletedTexts = ["Fictional deleted alpha", "Fictional deleted beta", "Fictional deleted gamma"]
        for (index, text) in deletedTexts.enumerated() {
            try await store.append(entry: Self.entry(text, daysAgo: Double(90 - index * 40)))
        }
        try await store.deleteAll()
        try await store.append(entry: Self.entry("Fictional new dictation", daysAgo: 0))

        let previousURL = StorageFilePreservation.previousCopyURL(for: url)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let names = Set(files.map(\.lastPathComponent))
        #expect(names.contains(url.lastPathComponent))
        #expect(names.contains(previousURL.lastPathComponent))
        for file in files {
            let contents = try Data(contentsOf: file)
            for text in deletedTexts {
                #expect(contents.range(of: Data(text.utf8)) == nil, "\(file.lastPathComponent) still holds \(text)")
            }
        }
        #expect(try String(contentsOf: url, encoding: .utf8).contains("Fictional new dictation"))
    }

    @Test("Delete all removes copies kept from a damaged History file and nothing else")
    func deleteAllRemovesRecoveryCopies() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryDeleteAll-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("transcript-history.json")
        let deletedText = Data("Fictional text from a damaged file".utf8)
        let recoveryCopies = [
            "transcript-history.original-20260101T120000Z.json",
            "transcript-history.original-20260101T120000Z-2.json",
            "transcript-history.unreadable-20260214T080910Z.json",
        ]
        let unrelated = [
            "preferences.original-20260101T120000Z.json",
            "transcript-history.original-notes.json",
            "transcript-history.unreadable-20260214T080910Z.json.bak",
            "my transcript-history.original-20260101T120000Z.json",
        ]
        for name in recoveryCopies + unrelated {
            try deletedText.write(to: directory.appendingPathComponent(name))
        }
        // The current file is damaged too, so Delete all first moves it aside.
        try Data("[{\"rawText\": \"Fictional text from a damaged file\"".utf8).write(to: url)
        let store = HistoryStore(storageURL: url, clipboardService: MemoryClipboardService())
        _ = await store.recent(limit: 10)

        try await store.deleteAll()

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") })
        #expect(remaining == Set(unrelated + [url.lastPathComponent]))
        #expect(try Data(contentsOf: url).range(of: deletedText) == nil)
        #expect(await store.recent(limit: 10).isEmpty)
    }
}
