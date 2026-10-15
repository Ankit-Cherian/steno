import Foundation
import Testing
import StenoKitTestSupport
@testable import StenoKit

private actor NamedMicrophoneCapture: AudioCaptureService {
    private let audioURL: URL
    private var names: [SessionID: String] = [:]

    init(audioURL: URL) {
        self.audioURL = audioURL
    }

    func beginCapture(sessionID: SessionID) async throws {
        names[sessionID] = "Studio Mic"
    }

    func endCapture(sessionID: SessionID) async throws -> URL {
        try await Task.sleep(for: .milliseconds(20))
        return audioURL
    }

    func cancelCapture(sessionID: SessionID) async {
        names[sessionID] = nil
    }

    func takeInputDeviceName(sessionID: SessionID) async -> String? {
        names.removeValue(forKey: sessionID)
    }
}

/// Returns a fixed insertion result, as a transport deciding to copy would.
private struct FixedResultInsertionService: InsertionServiceProtocol {
    let result: InsertResult

    func insert(text: String, target: AppContext) async -> InsertResult {
        var result = result
        result.insertedText = text
        return result
    }
}

/// Runs one dictation through a coordinator and returns the record History saved.
private func recordedDictation(
    insertionService: any InsertionServiceProtocol,
    copyingBecause copyReason: InsertionCopyReason? = nil,
    transcript: String = "the meeting is at noon",
    styleProfileService: StyleProfileService = StyleProfileService()
) async throws -> DictationRecord {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("record-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let audioURL = directory.appendingPathComponent("audio.wav")
    try Data().write(to: audioURL)
    let history = HistoryStore(
        storageURL: directory.appendingPathComponent("history.json")
    )
    let coordinator = SessionCoordinator(
        captureService: NamedMicrophoneCapture(audioURL: audioURL),
        transcriptionEngine: StaticTranscriptionEngine { _, _ in
            RawTranscript(text: transcript, durationMS: 1_000)
        },
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: insertionService,
        historyStore: history,
        lexiconService: PersonalLexiconService(),
        styleProfileService: styleProfileService
    )
    let sessionID = try await coordinator.startPressToTalk(
        appContext: AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
    )
    try await coordinator.endPressToTalkCapture(sessionID: sessionID)
    _ = try await coordinator.completePressToTalk(sessionID: sessionID, copyingBecause: copyReason)
    let entry = try #require(await history.recent(limit: 1).first)
    return try #require(entry.record)
}

/// A style service whose profile removes every filler word.
private func thoroughFillerRemoval() -> StyleProfileService {
    StyleProfileService(globalProfile: StyleProfile(
        name: "Thorough", tone: .natural, structureMode: .natural, fillerPolicy: .aggressive, commandPolicy: .passthrough))
}

@Suite("What happened to each dictation")
struct SessionCoordinatorRecordTests {
    @Test("A finished dictation saves how long each step took, where it went and what cleanup changed")
    func recordIsSaved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("audio.wav")
        try Data().write(to: audioURL)

        let history = HistoryStore(
            storageURL: directory.appendingPathComponent("history.json")
        )
        let coordinator = SessionCoordinator(
            captureService: NamedMicrophoneCapture(audioURL: audioURL),
            transcriptionEngine: StaticTranscriptionEngine { _, _ in
                try await Task.sleep(for: .milliseconds(60))
                return RawTranscript(text: "um so the meeting is at noon", durationMS: 1_500)
            },
            cleanupEngine: RuleBasedCleanupEngine(),
            insertionService: InsertionService(transports: [
                ClosureInsertionTransport(method: .direct) { _, _ in
                    try? await Task.sleep(for: .milliseconds(40))
                },
            ]),
            historyStore: history,
            lexiconService: PersonalLexiconService(),
            styleProfileService: StyleProfileService(),
            recordSettings: DictationRecordSettings(modelName: "Small", modelID: "ggml-small.en", vadEnabled: true)
        )

        let sessionID = try await coordinator.startPressToTalk(
            appContext: AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
        )
        try await Task.sleep(for: .milliseconds(30))
        let result = try await coordinator.stopPressToTalk(sessionID: sessionID)
        #expect(result.status == .inserted)

        let entry = try #require(await history.recent(limit: 1).first)
        let record = try #require(entry.record)
        #expect((record.recordingMS ?? 0) >= 30)
        #expect((record.transcriptionMS ?? 0) >= 60)
        #expect(record.cleanupMS != nil)
        #expect((record.insertionMS ?? 0) >= 40)
        #expect(record.microphoneName == "Studio Mic")
        #expect(record.modelName == "Small")
        #expect(record.insertionMethod == "typed")
        #expect(record.appName == "Notes")
        #expect(record.cleanupChanges == CleanupChangeRecord.changes(from: entry.rawText, to: entry.cleanText))
        // Default cleanup keeps fillers as spoken and capitalizes the first word.
        #expect(entry.cleanText == "Um so the meeting is at noon")
        #expect(record.cleanupChanges == [CleanupChangeRecord(kind: "replaced", before: "um", after: "Um")])
        #expect(record.schemaVersion == 1)
        #expect(record.attemptID == sessionID)
        #expect(record.outcome == "inserted")
        #expect(record.copyReason == nil)
        // Stop to insertion finished covers transcription and insertion.
        #expect((record.endToEndMS ?? 0) >= 100)
        #expect(record.modelID == "ggml-small.en")
        #expect(record.vadEnabled == true)
        #expect(record.language == "en-US")
        #expect(record.cleanupStyle == "balanced")
        #expect(record.appBundleID == "com.apple.Notes")
        #expect(entry.fixes == nil)
    }

    @Test("A copied dictation and a pasted one are told apart")
    func copiedAndPastedMethods() {
        #expect(DictationRecord.outcomeName(for: InsertResult(status: .inserted, method: .direct, insertedText: "x")) == "inserted")
        #expect(DictationRecord.outcomeName(for: InsertResult(status: .inserted, method: .clipboardPaste, insertedText: "x")) == "pasted")
        #expect(DictationRecord.outcomeName(for: InsertResult(status: .copiedOnly, method: .clipboardPaste, insertedText: "x", pasteAttempted: true)) == "pasted")
        #expect(DictationRecord.outcomeName(for: InsertResult(status: .copiedOnly, method: .clipboardPaste, insertedText: "x")) == "copied")
        #expect(DictationRecord.outcomeName(for: InsertResult(status: .failed, method: .none, insertedText: "x")) == "failed")
        #expect(DictationRecord.outcomeName(for: InsertResult(status: .noSpeech, method: .none, insertedText: "")) == "noSpeech")
        var copied = InsertResult(status: .copiedOnly, method: .clipboardPaste, insertedText: "x")
        #expect(DictationRecord.insertionMethodName(for: copied) == "copied")
        copied.pasteAttempted = true
        #expect(DictationRecord.insertionMethodName(for: copied) == "pasted")
        #expect(DictationRecord.insertionMethodName(for: InsertResult(status: .inserted, method: .accessibility, insertedText: "x")) == "accessibility")
        #expect(DictationRecord.insertionMethodName(for: InsertResult(status: .failed, method: .none, insertedText: "x")) == nil)
    }

    @Test("A dictation copied because the field was secure records why")
    func secureFieldCopyIsRecorded() async throws {
        let record = try await recordedDictation(insertionService: FixedResultInsertionService(result: InsertResult(
            status: .copiedOnly,
            method: .clipboardPaste,
            insertedText: "",
            copyReason: .secureField
        )))
        #expect(record.outcome == "copied")
        #expect(record.copyReason == "secureField")
        #expect(record.insertionMethod == "copied")
    }

    @Test("A restored dictation copied because another app was in front records why")
    func appChangedCopyIsRecorded() async throws {
        let record = try await recordedDictation(
            insertionService: InsertionService(transports: [
                ClipboardInsertionTransport(clipboard: MemoryClipboardService()),
            ]),
            copyingBecause: .appChanged
        )
        #expect(record.outcome == "copied")
        #expect(record.copyReason == "appChanged")
        #expect(record.insertionMethod == "copied")
    }

    @Test("A dictation not pasted because the clipboard changed is recorded as not pasted, with no copy reason")
    func clipboardChangedIsNotPasted() async throws {
        let record = try await recordedDictation(insertionService: FixedResultInsertionService(result: InsertResult(
            status: .copiedOnly,
            method: .clipboardPaste,
            insertedText: "",
            copyReason: .clipboardChanged
        )))
        #expect(record.outcome == "notPasted")
        #expect(record.copyReason == nil)
        #expect(record.insertionMethod == nil)
    }

    @Test("A dictation with more changes than the list keeps saves the full count")
    func changeCountPastTheListLimitIsRecorded() async throws {
        let transcript = (0..<30).flatMap { ["um", "word\($0)"] }.joined(separator: " ")
        let record = try await recordedDictation(
            insertionService: InsertionService(transports: [ClosureInsertionTransport(method: .direct) { _, _ in }]),
            transcript: transcript,
            styleProfileService: thoroughFillerRemoval())
        #expect(record.cleanupChanges?.count == CleanupChangeRecord.maximumCount)
        #expect((record.cleanupChangeCount ?? 0) >= 30)
        #expect(record.cleanupComparisonSkipped == nil)
    }

    @Test("A dictation too long to compare records that the comparison was skipped")
    func skippedComparisonIsRecorded() async throws {
        let transcript = "um " + (0..<1_600).map { "word\($0)" }.joined(separator: " ") + " um"
        let record = try await recordedDictation(
            insertionService: InsertionService(transports: [ClosureInsertionTransport(method: .direct) { _, _ in }]),
            transcript: transcript,
            styleProfileService: thoroughFillerRemoval())
        #expect(record.cleanupChanges == nil)
        #expect(record.cleanupChangeCount == nil)
        #expect(record.cleanupComparisonSkipped == true)
    }

    @Test("A dictation cleanup left alone records an empty comparison, not a skipped one")
    func emptyComparisonIsRecorded() async throws {
        let record = try await recordedDictation(
            insertionService: InsertionService(transports: [ClosureInsertionTransport(method: .direct) { _, _ in }]),
            transcript: "The meeting is at noon.")
        #expect(record.cleanupChanges == [])
        #expect(record.cleanupChangeCount == 0)
        #expect(record.cleanupComparisonSkipped == nil)
    }
}
