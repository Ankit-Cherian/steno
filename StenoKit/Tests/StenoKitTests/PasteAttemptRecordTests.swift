#if os(macOS)
import Foundation
import Testing
@testable import StenoKit

private let terminalContext = AppContext(
    bundleIdentifier: "com.apple.Terminal",
    appName: "Terminal"
)

/// The History entry shape exactly as Steno 1.0.0 declared and decoded it.
private struct PublishedTranscriptEntry: Codable {
    var id: UUID
    var createdAt: Date
    var appBundleID: String
    var rawText: String
    var cleanText: String
    var durationMS: Int
    var audioURL: URL?
    var insertionStatus: PublishedInsertionStatus
}

private enum PublishedInsertionStatus: String, Codable {
    case inserted
    case copiedOnly
    case failed
    case noSpeech
}

@Test("A sent paste is recorded as attempted; a copy-only result is not")
func insertResultRecordsPasteAttempt() async {
    let keys = FakeKeyPoster()
    let pasted = await makeProductionInsertionService(
        clipboard: MemoryClipboardService(),
        keys: keys,
        activator: FakeApplicationActivator(
            frontmost: terminalContext.bundleIdentifier,
            running: [terminalContext.bundleIdentifier]
        ),
        accessibility: FakeAccessibilityClient(focusedBundle: terminalContext.bundleIdentifier)
    ).insert(text: "git log", target: terminalContext)

    #expect(keys.commandShortcuts.count == 1)
    #expect(pasted.status == .copiedOnly)
    #expect(pasted.pasteAttempted == true)

    let copied = await makeProductionInsertionService(
        clipboard: MemoryClipboardService(),
        keys: FakeKeyPoster(),
        activator: FakeApplicationActivator(frontmost: "com.apple.Notes", running: ["com.apple.Notes"]),
        accessibility: FakeAccessibilityClient(focusedBundle: "com.apple.Notes")
    ).insert(text: "git log", target: terminalContext)

    #expect(copied.status == .copiedOnly)
    #expect(copied.pasteAttempted == nil)
}

@Test("History records an attempted paste through the production coordinator")
func historyRecordsPasteAttempt() async throws {
    let accessibility = FakeAccessibilityClient(focusedBundle: terminalContext.bundleIdentifier)
    let service = makeProductionInsertionService(
        clipboard: MemoryClipboardService(),
        keys: FakeKeyPoster(),
        activator: FakeApplicationActivator(
            frontmost: terminalContext.bundleIdentifier,
            running: [terminalContext.bundleIdentifier]
        ),
        accessibility: accessibility
    )
    let harness = try makeProductionCoordinator(
        recognizedText: "list the files",
        insertionService: service,
        accessibility: accessibility
    )

    let sessionID = try await harness.coordinator.startPressToTalk(
        appContext: terminalContext,
        options: SessionStartOptions()
    )
    let result = try await harness.coordinator.stopPressToTalk(sessionID: sessionID)
    let entry = try #require(await harness.historyStore.recent(limit: 1).first)

    #expect(result.pasteAttempted == true)
    #expect(entry.insertionStatus == .copiedOnly)
    #expect(entry.pasteAttempted == true)
}

@Test("History written with the paste flag still loads in the 1.0.0 decoder")
func pasteAttemptFieldLoadsInPublishedDecoder() throws {
    let entries = [
        TranscriptEntry(
            appBundleID: terminalContext.bundleIdentifier,
            rawText: "list the files",
            cleanText: "List the files.",
            durationMS: 1_200,
            audioURL: nil,
            insertionStatus: .copiedOnly,
            pasteAttempted: true
        ),
        TranscriptEntry(
            appBundleID: "com.apple.TextEdit",
            rawText: "hello",
            cleanText: "Hello.",
            audioURL: nil,
            insertionStatus: .inserted
        )
    ]
    let data = try JSONEncoder().encode(entries)

    let published = try JSONDecoder().decode([PublishedTranscriptEntry].self, from: data)
    #expect(published.map(\.insertionStatus) == [.copiedOnly, .inserted])
    #expect(published.map(\.cleanText) == ["List the files.", "Hello."])

    // Entries without an attempted paste encode exactly as 1.0.0 did.
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.components(separatedBy: "pasteAttempted").count == 2)

    // And a 1.0.0 file loads in the current decoder with no paste flag.
    let publishedData = try JSONEncoder().encode(published)
    let reloaded = try JSONDecoder().decode([TranscriptEntry].self, from: publishedData)
    #expect(reloaded.map(\.pasteAttempted) == [nil, nil])
}
#endif
