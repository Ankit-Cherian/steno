import Foundation
import Testing
@testable import StenoKit

@Suite("Dictation record and fixes in History files")
struct DictationRecordCodingTests {
    private static func entry(_ clean: String) -> TranscriptEntry {
        TranscriptEntry(
            // Whole seconds, as History's ISO 8601 dates store them.
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            appBundleID: "com.example.editor",
            rawText: clean.lowercased(),
            cleanText: clean,
            audioURL: nil,
            insertionStatus: .inserted
        )
    }

    /// A record with every field set, so a field missing from encoding or decoding fails the
    /// round trip.
    static let recordWithEveryField = DictationRecord(
        schemaVersion: 1,
        attemptID: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"),
        outcome: "copied",
        copyReason: "secureField",
        recordingMS: 4_200,
        transcriptionMS: 610,
        cleanupMS: 4,
        insertionMS: 35,
        endToEndMS: 700,
        microphoneName: "MacBook Pro Microphone",
        modelName: "Small",
        modelID: "ggml-small.en",
        language: "en-US",
        vadEnabled: true,
        cleanupStyle: "balanced",
        insertionMethod: "copied",
        appName: "Notes",
        appBundleID: "com.apple.Notes",
        cleanupChanges: [CleanupChangeRecord(kind: "removed", before: "um", after: nil)],
        cleanupChangeCount: 31,
        cleanupComparisonSkipped: true
    )

    @Test("Every record field is written and read back")
    func everyFieldRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Self.recordWithEveryField)
        let keys = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys) == [
            "schemaVersion", "attemptID", "outcome", "copyReason", "recordingMS", "transcriptionMS",
            "cleanupMS", "insertionMS", "endToEndMS", "microphoneName", "modelName", "modelID",
            "language", "vadEnabled", "cleanupStyle", "insertionMethod", "appName", "appBundleID",
            "cleanupChanges", "cleanupChangeCount", "cleanupComparisonSkipped",
        ])
        #expect(try JSONDecoder().decode(DictationRecord.self, from: data) == Self.recordWithEveryField)
    }

    @Test("A record saved before the change count was kept decodes without it, and a count that can't be read is left out")
    func changeCountIsOptional() throws {
        let old = #"{"schemaVersion":1,"outcome":"inserted","cleanupChanges":[{"kind":"added","after":"."}]}"#
        let record = try JSONDecoder().decode(DictationRecord.self, from: Data(old.utf8))
        #expect(record.cleanupChanges == [CleanupChangeRecord(kind: "added", before: nil, after: ".")])
        #expect(record.cleanupChangeCount == nil)
        #expect(record.cleanupComparisonSkipped == nil)

        let skipped = #"{"schemaVersion":1,"cleanupComparisonSkipped":true}"#
        let skippedRecord = try JSONDecoder().decode(DictationRecord.self, from: Data(skipped.utf8))
        #expect(skippedRecord.cleanupChanges == nil)
        #expect(skippedRecord.cleanupComparisonSkipped == true)

        let unreadable = #"{"schemaVersion":1,"outcome":"inserted","cleanupChangeCount":"many","cleanupComparisonSkipped":3}"#
        let log = DecodingIssueLog()
        let tolerated = try JSONDecoder.recordingIssues(to: log).decode(DictationRecord.self, from: Data(unreadable.utf8))
        #expect(tolerated.outcome == "inserted")
        #expect(tolerated.cleanupChangeCount == nil)
        #expect(tolerated.cleanupComparisonSkipped == nil)
        #expect(log.replacedCount > 0)

        // Written with the new fields, a record reads back whole.
        let written = DictationRecord(
            schemaVersion: 1, outcome: "inserted", cleanupChanges: [], cleanupChangeCount: 0)
        let reread = try JSONDecoder().decode(DictationRecord.self, from: JSONEncoder().encode(written))
        #expect(reread == written)
    }

    @Test("An outcome or method written by a newer version still decodes")
    func unknownFutureValuesDecode() throws {
        let json = """
        {"schemaVersion":7,"outcome":"sampleOutcome","insertionMethod":"sampleMethod","copyReason":"newReason","modelID":"ggml-tiny"}
        """
        let record = try JSONDecoder().decode(DictationRecord.self, from: Data(json.utf8))
        #expect(record.schemaVersion == 7)
        #expect(record.outcome == "sampleOutcome")
        #expect(record.insertionMethod == "sampleMethod")
        #expect(record.copyReason == "newReason")
        #expect(record.modelID == "ggml-tiny")

        let entryJSON = """
        [{"id":"\(UUID().uuidString)","createdAt":"2026-10-05T10:00:00Z","appBundleID":"com.example.editor",
          "rawText":"hi","cleanText":"Hi","durationMS":0,"insertionStatus":"inserted",
          "record":{"outcome":"sampleOutcome","attemptID":"\(UUID().uuidString)"}}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([TranscriptEntry].self, from: Data(entryJSON.utf8))
        #expect(entries.first?.record?.outcome == "sampleOutcome")
        #expect(entries.first?.record?.attemptID != nil)
    }

    @Test("Entries with a full record and fixes round-trip, decode in 1.0.0, and old entries read them as nil")
    func roundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-coding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storageURL = directory.appendingPathComponent("transcript-history.json")
        var entry = Self.entry("Ship it.")
        entry.record = Self.recordWithEveryField
        entry.fixes = [WordFix(original: "ship", replacement: "Ship", occurrence: 0, appliesToFuture: false, date: Date(timeIntervalSince1970: 1_790_000_000), location: 0)]
        let old = Self.entry("Saved by 1.0")

        let writer = HistoryStore(storageURL: storageURL)
        try await writer.append(entry: old)
        try await writer.append(entry: entry)

        let reader = HistoryStore(storageURL: storageURL)
        let reloaded = await reader.recent(limit: 10)
        #expect(await reader.takeRecoveryNotices().isEmpty)
        #expect(reloaded.first { $0.id == entry.id } == entry)
        #expect(reloaded.first { $0.id == old.id }?.record == nil)
        #expect(reloaded.first { $0.id == old.id }?.fixes == nil)

        let encoded = try String(decoding: Data(contentsOf: storageURL), as: UTF8.self)
        #expect(encoded.components(separatedBy: "\"record\"").count == 2)
        #expect(encoded.components(separatedBy: "\"fixes\"").count == 2)

        let released = try Released100.decoder().decode(
            [Released100.TranscriptEntry].self,
            from: Data(contentsOf: storageURL)
        )
        #expect(Set(released.map(\.id)) == [entry.id, old.id])
        #expect(released.first { $0.id == entry.id }?.cleanText == "Ship it.")
    }

    @Test("A record or fix this version can't read is left out, and the entry still loads")
    func unreadableDetailsKeepEntry() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","createdAt":"2026-10-05T10:00:00Z","appBundleID":"com.example.editor",
          "rawText":"hi","cleanText":"Hi","durationMS":0,"insertionStatus":"inserted",
          "record":{"recordingMS":"soon","modelName":"Small","cleanupChanges":[{"before":"x"},{"kind":"added","after":"."}]},
          "fixes":[{"original":"Hi"},{"original":"hi","replacement":"Hi","occurrence":0,"appliesToFuture":false,"date":"2026-10-05T10:00:00Z"}]},
         {"id":"\(UUID().uuidString)","createdAt":"2026-10-05T10:00:00Z","appBundleID":"com.example.editor",
          "rawText":"yo","cleanText":"Yo","durationMS":0,"insertionStatus":"inserted","record":7,"fixes":{"a":1}}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([TranscriptEntry].self, from: Data(json.utf8))
        #expect(entries.count == 2)
        #expect(entries[0].record?.recordingMS == nil)
        #expect(entries[0].record?.modelName == "Small")
        #expect(entries[0].record?.cleanupChanges == [CleanupChangeRecord(kind: "added", before: nil, after: ".")])
        #expect(entries[0].fixes?.map(\.original) == ["hi"])
        #expect(entries[1].record == nil)
        #expect(entries[1].fixes == nil)
    }

    /// Writes `json` as the History file, loads it, and saves one more entry so this version
    /// rewrites the file.
    private static func loadAndRewrite(_ json: String) async throws -> (entries: [TranscriptEntry], notices: [StorageRecoveryNotice], original: Data, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storageURL = directory.appendingPathComponent("transcript-history.json")
        let original = Data(json.utf8)
        try original.write(to: storageURL)
        let store = HistoryStore(storageURL: storageURL)
        let entries = await store.recent(limit: 10)
        try await store.append(entry: entry("Written by this version"))
        return (entries, await store.takeRecoveryNotices(), original, directory)
    }

    private static func storedEntry(record: String = "null", fixes: String = "null") -> String {
        """
        {"id":"\(UUID().uuidString)","createdAt":"2026-10-05T10:00:00Z","appBundleID":"com.example.editor",
         "rawText":"hi","cleanText":"Hi","durationMS":0,"insertionStatus":"inserted","record":\(record),"fixes":\(fixes)}
        """
    }

    @Test("A record from a newer format keeps a copy of the original file before it is rewritten")
    func newerRecordKeepsOriginal() async throws {
        let result = try await Self.loadAndRewrite("[" + Self.storedEntry(
            record: #"{"schemaVersion":2,"outcome":"inserted","laterDetail":{"a":1}}"#
        ) + "]")
        defer { try? FileManager.default.removeItem(at: result.directory) }

        #expect(result.entries.first?.record?.schemaVersion == 2)
        let notice = try #require(result.notices.first)
        #expect(result.notices.count == 1)
        #expect(try Data(contentsOf: try #require(notice.fileURL)) == result.original)
        #expect(!notice.message.contains("hidden"))
    }

    @Test("A record field this version can't read keeps a copy of the original file")
    func unreadableFieldKeepsOriginal() async throws {
        let result = try await Self.loadAndRewrite("[" + Self.storedEntry(
            record: #"{"schemaVersion":1,"recordingMS":"soon"}"#
        ) + "]")
        defer { try? FileManager.default.removeItem(at: result.directory) }

        #expect(result.entries.first?.record?.recordingMS == nil)
        let notice = try #require(result.notices.first)
        #expect(try Data(contentsOf: try #require(notice.fileURL)) == result.original)
    }

    @Test("A cleanup change or fix that can't be read isn't counted as a hidden entry")
    func skippedDetailsAreNotHiddenEntries() async throws {
        let result = try await Self.loadAndRewrite("[" + Self.storedEntry(
            record: #"{"schemaVersion":1,"cleanupChanges":[{"before":"x"},{"kind":"added","after":"."}]}"#,
            fixes: #"[{"original":"Hi"}]"#
        ) + "]")
        defer { try? FileManager.default.removeItem(at: result.directory) }

        #expect(result.entries.count == 1)
        #expect(result.entries.first?.record?.cleanupChanges?.count == 1)
        let notice = try #require(result.notices.first)
        #expect(result.notices.count == 1)
        #expect(!notice.message.contains("hidden"))
        #expect(!notice.message.contains("couldn\u{2019}t be read"))
        #expect(!notice.message.contains("couldn't be read"))
        #expect(!notice.message.contains("default status"))
        #expect(try Data(contentsOf: try #require(notice.fileURL)) == result.original)
    }

    @Test("A current record that reads in full raises no notice")
    func currentRecordIsQuiet() async throws {
        let result = try await Self.loadAndRewrite("[" + Self.storedEntry(
            record: #"{"schemaVersion":1,"outcome":"copied","cleanupChanges":[{"kind":"added","after":"."}]}"#
        ) + "]")
        defer { try? FileManager.default.removeItem(at: result.directory) }
        #expect(result.notices.isEmpty)
    }
}
