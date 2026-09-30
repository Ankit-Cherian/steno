import Foundation
import Testing
@testable import StenoKit

/// Builds damaged History files the way real files get damaged: a newer build
/// writes values this build doesn't know, an external edit drops a field or
/// truncates the file, or permissions change.
@Suite("History store damaged-file recovery", .serialized)
struct HistoryStoreRecoveryTests {
    enum Damage: String, CaseIterable, CustomTestStringConvertible {
        case unknownInsertionStatus
        case missingRequiredField
        case differentTopLevelShape
        case truncatedJSON
        case unreadableFile

        var testDescription: String { rawValue }

        /// Damage that keeps the rest of the file usable, so the good entries load.
        var keepsReadableEntries: Bool {
            self == .unknownInsertionStatus || self == .missingRequiredField
        }
    }

    @Test("Append and delete after a damaged load never lose the original bytes", arguments: Damage.allCases)
    func appendAndDeletePreserveOriginal(damage: Damage) async throws {
        let fixture = try HistoryFixture(entryCount: 300)
        defer { fixture.cleanUp() }
        let original = try fixture.writeDamaged(damage)

        let store = fixture.store()
        let loaded = await store.recent(limit: 1_000)
        switch damage {
        case .unknownInsertionStatus:
            #expect(loaded.count == 300)
            #expect(loaded.first(where: { $0.id == fixture.damagedEntryID })?.insertionStatus == .copiedOnly)
        case .missingRequiredField:
            #expect(loaded.count == 299)
        case .differentTopLevelShape, .truncatedJSON, .unreadableFile:
            #expect(loaded.isEmpty)
        }

        let added = HistoryFixture.entry("Appended after damaged load")
        try await store.append(entry: added)
        let deleted = damage.keepsReadableEntries ? fixture.goodEntryIDs[0] : added.id
        try await store.delete(entryID: deleted)

        fixture.restorePermissions()
        let copies = try fixture.filesContaining(original)
        #expect(!copies.isEmpty, "The original file content must survive in place or moved aside")
        #expect(copies.allSatisfy { $0.lastPathComponent != fixture.storageURL.lastPathComponent })

        let onDisk = try fixture.decodeMainFile()
        if damage.keepsReadableEntries {
            let expectedCount = damage == .unknownInsertionStatus ? 300 : 299
            #expect(onDisk.count == expectedCount)
            #expect(onDisk.first?.id == added.id)
            #expect(!onDisk.contains { $0.id == deleted })
        } else {
            #expect(onDisk.isEmpty)
        }
    }

    @Test("A damaged load is reported once with the file that holds the original content", arguments: Damage.allCases)
    func damagedLoadIsReportedOnce(damage: Damage) async throws {
        let fixture = try HistoryFixture(entryCount: 20)
        defer { fixture.cleanUp() }
        let original = try fixture.writeDamaged(damage)
        let store = fixture.store()
        _ = await store.recent(limit: 10)
        try await store.append(entry: HistoryFixture.entry("New"))

        let notices = await store.takeRecoveryNotices()
        #expect(!notices.isEmpty)
        #expect(await store.takeRecoveryNotices().isEmpty, "Each notice is delivered once")
        fixture.restorePermissions()
        let revealed = try #require(notices.last?.fileURL)
        #expect(try Data(contentsOf: revealed) == original)
    }

    @Test("An unreadable file is moved aside, so the next launch reads the replacement")
    func unreadableFileDoesNotWipeEveryLaunch() async throws {
        let fixture = try HistoryFixture(entryCount: 50)
        defer { fixture.cleanUp() }
        _ = try fixture.writeDamaged(.unreadableFile)

        let firstLaunch = fixture.store()
        try await firstLaunch.append(entry: HistoryFixture.entry("First session"))

        let secondLaunch = fixture.store()
        #expect(await secondLaunch.recent(limit: 10).map(\.rawText) == ["First session"])
        try await secondLaunch.append(entry: HistoryFixture.entry("Second session"))
        #expect(await fixture.store().recent(limit: 10).count == 2)
        #expect(await secondLaunch.takeRecoveryNotices().isEmpty)
    }

    @Test("A file that becomes readable again is used instead of being replaced")
    func transientReadFailureRetriesBeforeWriting() async throws {
        let fixture = try HistoryFixture(entryCount: 30)
        defer { fixture.cleanUp() }
        _ = try fixture.writeDamaged(.unreadableFile)
        let store = fixture.store()
        #expect(await store.recent(limit: 100).isEmpty)

        fixture.restorePermissions()
        try await store.append(entry: HistoryFixture.entry("After recovery"))
        let onDisk = try fixture.decodeMainFile()
        #expect(onDisk.count == 31)
    }

    @Test("An empty or whitespace file counts as empty history without a notice", arguments: ["", "  \n", "[]"])
    func emptyFilesAreEmptyHistory(contents: String) async throws {
        let fixture = try HistoryFixture(entryCount: 0)
        defer { fixture.cleanUp() }
        try Data(contents.utf8).write(to: fixture.storageURL)
        let store = fixture.store()
        #expect(await store.recent(limit: 10).isEmpty)
        try await store.append(entry: HistoryFixture.entry("First"))
        #expect(try fixture.decodeMainFile().count == 1)
        #expect(await store.takeRecoveryNotices().isEmpty)
    }

    @Test("A write that can't move an unreadable file aside is refused and leaves the file alone")
    func refusesWriteWhenOriginalCannotBePreserved() async throws {
        let fixture = try HistoryFixture(entryCount: 10)
        defer { fixture.cleanUp() }
        let original = try fixture.writeDamaged(.truncatedJSON)
        let store = fixture.store()
        _ = await store.recent(limit: 10)

        fixture.makeDirectoryReadOnly()
        await #expect(throws: HistoryStoreError.self) {
            try await store.append(entry: HistoryFixture.entry("Refused"))
        }
        fixture.restorePermissions()
        #expect(try Data(contentsOf: fixture.storageURL) == original)
    }

    @Test("Each successful write keeps the previous good copy")
    func keepsPreviousGoodCopy() async throws {
        let fixture = try HistoryFixture(entryCount: 0)
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let first = HistoryFixture.entry("First")
        try await store.append(entry: first)
        try await store.append(entry: HistoryFixture.entry("Second"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let previous = try decoder.decode(
            [TranscriptEntry].self,
            from: Data(contentsOf: fixture.previousCopyURL)
        )
        #expect(previous.map(\.id) == [first.id])
    }

    @Test("A failed delete leaves memory and disk unchanged")
    func failedDeleteIsRolledBack() async throws {
        let fixture = try HistoryFixture(entryCount: 0)
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let kept = HistoryFixture.entry("Kept")
        try await store.append(entry: kept)

        fixture.makeDirectoryReadOnly()
        await #expect(throws: HistoryStoreError.self) {
            try await store.delete(entryID: kept.id)
        }
        #expect(await store.recent(limit: 10).map(\.id) == [kept.id])
        fixture.restorePermissions()
        #expect(try fixture.decodeMainFile().map(\.id) == [kept.id])
    }
}

struct HistoryFixture {
    let directory: URL
    let storageURL: URL
    let goodEntryIDs: [UUID]
    let damagedEntryID: UUID
    private let entries: [TranscriptEntry]

    var previousCopyURL: URL {
        directory.appendingPathComponent("transcript-history.previous.json")
    }

    init(entryCount: Int) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storageURL = directory.appendingPathComponent("transcript-history.json")
        entries = (0..<entryCount).map { Self.entry("Fictional entry \($0)") }
        let damagedID = entries.dropFirst(entryCount / 2).first?.id ?? UUID()
        damagedEntryID = damagedID
        goodEntryIDs = entries.map(\.id).filter { $0 != damagedID }
    }

    static func entry(_ text: String) -> TranscriptEntry {
        TranscriptEntry(
            appBundleID: "com.example.editor",
            rawText: text,
            cleanText: text,
            durationMS: 1_200,
            audioURL: nil,
            insertionStatus: .inserted
        )
    }

    func store() -> HistoryStore {
        HistoryStore(storageURL: storageURL, clipboardService: MemoryClipboardService())
    }

    /// Writes the damaged file and returns its exact bytes.
    func writeDamaged(_ damage: HistoryStoreRecoveryTests.Damage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let valid = try encoder.encode(entries)
        var objects = try #require(JSONSerialization.jsonObject(with: valid) as? [[String: Any]])
        let damagedIndex = try #require(entries.firstIndex { $0.id == damagedEntryID })

        let data: Data
        switch damage {
        case .unknownInsertionStatus:
            objects[damagedIndex]["insertionStatus"] = "pastedLater"
            data = try JSONSerialization.data(withJSONObject: objects)
        case .missingRequiredField:
            objects[damagedIndex].removeValue(forKey: "durationMS")
            data = try JSONSerialization.data(withJSONObject: objects)
        case .differentTopLevelShape:
            data = try JSONSerialization.data(withJSONObject: ["version": 2, "entries": objects])
        case .truncatedJSON:
            data = valid.dropLast(40)
        case .unreadableFile:
            data = valid
        }
        try data.write(to: storageURL)
        if damage == .unreadableFile {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: storageURL.path)
        }
        return data
    }

    func makeDirectoryReadOnly() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    }

    func restorePermissions() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: directory.appendingPathComponent(name).path
            )
        }
    }

    func filesContaining(_ original: Data) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { (try? Data(contentsOf: $0)) == original }
    }

    func decodeMainFile() throws -> [TranscriptEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([TranscriptEntry].self, from: Data(contentsOf: storageURL))
    }

    func cleanUp() {
        restorePermissions()
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("History shared by two running copies")
struct HistoryStoreMultiProcessTests {
    @Test("Two stores on one file keep each other's appends and deletes")
    func interleavedWritesKeepBothCopies() async throws {
        let fixture = try HistoryFixture(entryCount: 0)
        defer { fixture.cleanUp() }
        let installed = fixture.store()
        let debugBuild = fixture.store()

        let a1 = HistoryFixture.entry("A1")
        try await installed.append(entry: a1)
        _ = await debugBuild.recent(limit: 10)
        try await debugBuild.append(entry: HistoryFixture.entry("B1"))
        try await debugBuild.append(entry: HistoryFixture.entry("B2"))
        try await installed.append(entry: HistoryFixture.entry("A2"))
        try await debugBuild.delete(entryID: a1.id)
        try await installed.append(entry: HistoryFixture.entry("A3"))

        #expect(try fixture.decodeMainFile().map(\.rawText) == ["A3", "A2", "B2", "B1"])
        #expect(await installed.recent(limit: 10).map(\.rawText) == ["A3", "A2", "B2", "B1"])
        #expect(await debugBuild.recent(limit: 10).map(\.rawText) == ["A3", "A2", "B2", "B1"])
    }

    @Test("Concurrent appends from two stores are all kept")
    func concurrentAppendsAreAllKept() async throws {
        let fixture = try HistoryFixture(entryCount: 0)
        defer { fixture.cleanUp() }
        let first = fixture.store()
        let second = fixture.store()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                let store = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    try await store.append(entry: HistoryFixture.entry("Concurrent \(index)"))
                }
            }
            try await group.waitForAll()
        }

        #expect(Set(try fixture.decodeMainFile().map(\.rawText)).count == 40)
    }
}
