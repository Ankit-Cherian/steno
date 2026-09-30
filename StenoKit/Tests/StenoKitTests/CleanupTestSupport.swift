import Foundation
import StenoKitTestSupport
@testable import StenoKit

/// Mean token confidence the recognizer typically reports for clear dictation.
let typicalDictationConfidence = 0.93

/// A transcript shaped like `WhisperTranscriptDecoder` output: one segment whose confidence is the
/// mean token probability, repeated as the utterance average. Pass `nil` for an unknown confidence.
func dictatedTranscript(_ text: String, confidence: Double? = typicalDictationConfidence) -> RawTranscript {
    guard let confidence else { return RawTranscript(text: text) }
    return RawTranscript(
        text: text,
        segments: [TranscriptSegment(startMS: 0, endMS: 2_000, text: text, confidence: confidence)],
        avgConfidence: confidence,
        durationMS: 2_000
    )
}

/// Vocabulary entries a new install ships with (AppPreferences.default).
let defaultVocabularyEntries: [LexiconEntry] = [
    LexiconEntry(term: "stenoh", preferred: "Steno", scope: .global),
    LexiconEntry(term: "steno kit", preferred: "StenoKit", scope: .global),
]

/// The style profile a new install ships with (AppPreferences.default).
let defaultStyleProfile = StyleProfile(
    name: "Default",
    tone: .natural,
    structureMode: .paragraph,
    fillerPolicy: .balanced,
    commandPolicy: .transform
)

private actor InsertedTextRecorder {
    var last: String?
    func record(_ text: String) { last = text }
}

/// Runs one dictation through SessionCoordinator, wired the way DictationController builds it,
/// and returns the text that was inserted.
func dictateThroughCoordinator(
    _ text: String,
    confidence: Double? = typicalDictationConfidence,
    entries: [LexiconEntry] = defaultVocabularyEntries,
    profile: StyleProfile = defaultStyleProfile,
    appContext: AppContext = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")
) async throws -> String? {
    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cleanup-e2e-\(UUID().uuidString).wav")
    try Data().write(to: audioURL)
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let historyURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cleanup-e2e-history-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: historyURL) }

    let raw = dictatedTranscript(text, confidence: confidence)
    let recorder = InsertedTextRecorder()
    let coordinator = SessionCoordinator(
        captureService: StubAudioCaptureService(queuedAudioURLs: [audioURL]),
        transcriptionEngine: StaticTranscriptionEngine { _, _ in raw },
        cleanupEngine: RuleBasedCleanupEngine(),
        insertionService: InsertionService(transports: [
            ClosureInsertionTransport(method: .direct) { inserted, _ in await recorder.record(inserted) }
        ]),
        historyStore: HistoryStore(storageURL: historyURL, clipboardService: MemoryClipboardService()),
        lexiconService: PersonalLexiconService(entries: entries),
        styleProfileService: StyleProfileService(globalProfile: profile, appProfiles: [:]),
        snippetService: SnippetService(snippets: []),
        fallbackCleanupEngine: RuleBasedCleanupEngine(),
        editorTargetCapture: { _ in .failure(.unsupportedElement) }
    )
    let sessionID = try await coordinator.startPressToTalk(appContext: appContext)
    _ = try await coordinator.stopPressToTalk(sessionID: sessionID)
    return await recorder.last
}
