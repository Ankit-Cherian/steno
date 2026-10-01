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

    private static func encoded(_ entry: TranscriptEntry) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(entry), as: UTF8.self)
    }

    @Test("A deleted entry is removed from recovery copies, and their other entries keep their bytes")
    func deleteRemovesEntryFromRecoveryCopies() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryDelete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("transcript-history.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let deleted = Self.entry("Fictional deleted note")
        let kept = Self.entry("Fictional kept note")
        // An entry this version can't decode, which is why such a copy exists.
        let undecodable = #"{"id" : "not-a-uuid",  "rawText":"Fictional damaged note \"quoted\" [x]"}"#
        let keptJSON = try Self.encoded(kept)
        let copy = "[\n  \(keptJSON) ,\n  \(try Self.encoded(deleted)),\n  \(undecodable)\n]\n"
        let originalCopy = directory.appendingPathComponent("transcript-history.original-20260101T000000Z.json")
        let unreadableCopy = directory.appendingPathComponent("transcript-history.unreadable-20260102T000000Z-2.json")
        try Data(copy.utf8).write(to: originalCopy)
        try Data(copy.utf8).write(to: unreadableCopy)

        let store = HistoryStore(storageURL: url, clipboardService: MemoryClipboardService())
        try await store.append(entry: deleted)
        try await store.append(entry: kept)
        _ = await store.takeRecoveryNotices()

        try await store.delete(entryID: deleted.id)

        let expected = "[\(keptJSON),\(undecodable)]\n"
        for file in [originalCopy, unreadableCopy] {
            let contents = try Data(contentsOf: file)
            #expect(contents.range(of: Data("Fictional deleted note".utf8)) == nil, "\(file.lastPathComponent) still holds the deleted text")
            #expect(String(decoding: contents, as: UTF8.self) == expected)
        }
        #expect(await store.takeRecoveryNotices().isEmpty)
    }

    @Test("A recovery copy that can't be parsed is left untouched, and the notice says Delete all removes it")
    func deleteLeavesUnparseableRecoveryCopyAndSaysSo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryDelete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("transcript-history.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let deleted = Self.entry("Fictional deleted note")
        let damaged = Data("[\(try Self.encoded(deleted)),{\"id\":\"trunc".utf8)
        let damagedCopy = directory.appendingPathComponent("transcript-history.unreadable-20260101T000000Z.json")
        try damaged.write(to: damagedCopy)

        let store = HistoryStore(storageURL: url, clipboardService: MemoryClipboardService())
        try await store.append(entry: deleted)
        try await store.append(entry: Self.entry("Fictional kept note"))
        _ = await store.takeRecoveryNotices()

        try await store.delete(entryID: deleted.id)

        #expect(try Data(contentsOf: damagedCopy) == damaged)
        #expect(await store.recent(limit: 10).allSatisfy { $0.id != deleted.id })
        let notices = await store.takeRecoveryNotices()
        #expect(notices.count == 1)
        #expect(notices.first?.message.contains("damaged copy") == true)
        #expect(notices.first?.message.contains("Delete all history") == true)
        #expect(notices.first?.fileURL?.lastPathComponent == damagedCopy.lastPathComponent)
    }

    @Test("Removing an entry from a kept copy changes nothing else")
    func removingEntryFromKeptCopy() throws {
        let id = UUID()
        let other = #"{"id":"\#(UUID().uuidString)","rawText":"a, [b] {c} \"d\""}"#
        let target = #"{"rawText":"x","id":"\#(id.uuidString.lowercased())"}"#
        #expect(HistoryStore.removingEntry(id, fromKeptCopy: Data("[\(other),\(target)]".utf8)) == .edited(Data("[\(other)]".utf8)))
        #expect(HistoryStore.removingEntry(id, fromKeptCopy: Data("[\(target)]".utf8)) == .edited(Data("[]".utf8)))
        #expect(HistoryStore.removingEntry(id, fromKeptCopy: Data("[\(other)]".utf8)) == .noMatch)
        #expect(HistoryStore.removingEntry(id, fromKeptCopy: Data("[]".utf8)) == .noMatch)
        #expect(HistoryStore.removingEntry(id, fromKeptCopy: Data("{\"id\":\"\(id.uuidString)\"}".utf8)) == .unparseable)
        #expect(HistoryStore.removingEntry(id, fromKeptCopy: Data("[\(target)".utf8)) == .unparseable)
    }
}
