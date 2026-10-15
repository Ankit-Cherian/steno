import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

/// Paste Last Dictation re-inserts the newest dictation. When that dictation was meant for a
/// secure field (its History entry is marked concealed), no copy of it may be plain and the
/// island must not show its words.
@MainActor
@Suite("PasteLastConcealment", .serialized)
struct PasteLastConcealmentTests {
    private static let secretText = "Hunter two"

    private func seedConcealedEntry(in history: HistoryStore) async throws {
        try await history.append(entry: TranscriptEntry(
            appBundleID: "com.example.steno-test-editor",
            rawText: "hunter two",
            cleanText: Self.secretText,
            audioURL: nil,
            insertionStatus: .copiedOnly,
            concealedCopy: true
        ))
    }

    // MARK: - Control: the harness does offer words for an ordinary dictation

    @Test("Control: Paste Last of an ordinary dictation inserts it and offers its first line on the island")
    func pasteLastOfAnOrdinaryDictationOffersItsWords() async throws {
        let harness = try PasteLastConcealmentHarness(firstTransportFails: false)
        defer { harness.removeDirectory() }
        try await harness.history.append(entry: TranscriptEntry(
            appBundleID: "com.example.steno-test-editor",
            rawText: "send it to sam",
            cleanText: "Send it to Sam",
            audioURL: nil,
            insertionStatus: .inserted
        ))

        harness.controller.pasteLastDictation()
        try #require(await concealmentEventually { await harness.transport.texts() == ["Send it to Sam"] })
        try #require(await concealmentEventually { @MainActor in harness.controller.recordingLifecycleState == .idle })

        let words = harness.presenter.hostedEvidenceRequestedWords()
        #expect(words.contains("Send it to Sam"), "probe: the island offers the words of an ordinary paste")
        await harness.finish()
    }


    @Test(
        "Paste Last of a concealed dictation offers no words on the island",
        arguments: ["default", "always"]
    )
    func pasteLastOfAConcealedDictationOffersNoWords(afterInserting: String) async throws {
        let harness = try PasteLastConcealmentHarness(firstTransportFails: false)
        defer { harness.removeDirectory() }
        if afterInserting == "always" {
            harness.controller.preferences.recording.afterInserting = "always"
        }
        try await seedConcealedEntry(in: harness.history)
        let seeded = await harness.history.recent(limit: 5)
        try #require(seeded.count == 1)
        try #require(seeded.first?.concealedCopy == true)

        harness.controller.pasteLastDictation()
        try #require(await concealmentEventually { await harness.transport.texts() == [Self.secretText] })
        try #require(await concealmentEventually { @MainActor in harness.controller.recordingLifecycleState == .idle })
        let states = harness.presenter.hostedEvidenceRequestedStates()
        try #require(states.contains { if case .result(.inserted, _) = $0 { return true } else { return false } })

        let words = harness.presenter.hostedEvidenceRequestedWords()
        #expect(words.allSatisfy { $0 == nil }, "island words were \(words.compactMap { $0 })")
        await harness.finish()
    }


    @Test("Paste Last of a concealed dictation copies it concealed when the insertion falls back to a copy")
    func pasteLastOfAConcealedDictationFallbackCopyIsConcealed() async throws {
        let harness = try PasteLastConcealmentHarness(firstTransportFails: true)
        defer { harness.removeDirectory() }
        try await seedConcealedEntry(in: harness.history)
        let seeded = await harness.history.recent(limit: 5)
        try #require(seeded.first?.concealedCopy == true)

        harness.controller.pasteLastDictation()
        try #require(await concealmentEventually { await harness.clipboard.latestValue == Self.secretText })
        try #require(await concealmentEventually { @MainActor in harness.controller.recordingLifecycleState == .idle })
        try #require(await harness.failing.attempts() == 1)
        try #require(await harness.transport.texts().isEmpty)

        let plainWrites = await harness.clipboard.plainValues()
        let concealedWrites = await harness.clipboard.concealedValues()
        #expect(plainWrites.isEmpty, "plain writes: \(plainWrites)")
        #expect(concealedWrites == [Self.secretText], "concealed writes: \(concealedWrites)")
        let words = harness.presenter.hostedEvidenceRequestedWords()
        #expect(words.allSatisfy { $0 == nil }, "island words were \(words.compactMap { $0 })")

        // The island's Copy offers the same result again; it must stay concealed too.
        harness.presenter.onCopyResult?()
        #expect(await concealmentEventually { await harness.clipboard.writeCount() == 2 })
        let plainAfterCopy = await harness.clipboard.plainValues()
        #expect(plainAfterCopy.isEmpty, "plain writes after island Copy: \(plainAfterCopy)")
        await harness.finish()
    }

    @Test("Paste Last of a concealed dictation that ends Not pasted keeps the island's Copy concealed")
    func pasteLastNotPastedIslandCopyStaysConcealed() async throws {
        let harness = try PasteLastConcealmentHarness(
            firstTransportFails: true,
            autoPasteOutcome: .skipped(reason: "Clipboard changed before auto-paste; nothing was pasted.", cause: .clipboardChanged)
        )
        defer { harness.removeDirectory() }
        try await seedConcealedEntry(in: harness.history)
        let seeded = await harness.history.recent(limit: 5)
        try #require(seeded.first?.concealedCopy == true)

        harness.controller.pasteLastDictation()
        try #require(await concealmentEventually { await harness.clipboard.latestValue == Self.secretText })
        try #require(await concealmentEventually { @MainActor in harness.controller.recordingLifecycleState == .idle })
        try #require(harness.presenter.hostedEvidenceRequestedStates().contains { state in
            if case .result(.notPasted, _) = state { return true } else { return false }
        })
        let plainBefore = await harness.clipboard.plainValues()
        let concealedBefore = await harness.clipboard.concealedValues()
        let writesBefore = plainBefore.count + concealedBefore.count

        // The island offers Copy for a Not pasted result.
        harness.presenter.onCopyResult?()
        try #require(await concealmentEventually { await harness.clipboard.writeCount() == writesBefore + 1 })

        let plainAfter = await harness.clipboard.plainValues()
        #expect(plainAfter.count == plainBefore.count, "the island Copy added a plain write: \(plainAfter)")
        let concealedAfter = await harness.clipboard.concealedValues()
        #expect(concealedAfter.count == concealedBefore.count + 1, "concealed writes: \(concealedAfter)")
        await harness.finish()
    }
}

// MARK: - Support

func concealmentEventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    await cancelTestEventually(condition)
}

/// An in-memory clipboard that records which writes were concealed.
actor WriteMarkRecordingClipboard: ClipboardService {
    private(set) var latestValue = ""
    private var plain: [String] = []
    private var concealed: [String] = []

    func setString(_ text: String) async throws {
        latestValue = text
        plain.append(text)
    }

    func setConcealedString(_ text: String) async throws {
        latestValue = text
        concealed.append(text)
    }

    func plainValues() -> [String] { plain }
    func concealedValues() -> [String] { concealed }
    func writeCount() -> Int { plain.count + concealed.count }
}

/// Fails every insertion, so the next transport (the clipboard) takes over.
private actor ConcealmentFailingTransport: InsertionTransport {
    nonisolated var method: InsertionMethod { .direct }
    private var count = 0
    func insert(text: String, target: AppContext) async throws {
        count += 1
        throw CocoaError(.fileWriteUnknown)
    }
    func attempts() -> Int { count }
}

private actor ConcealmentUnusedEngine: TranscriptionEngine {
    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> RawTranscript {
        RawTranscript(text: "unused")
    }
}

/// The real coordinator and insertion service over a recording clipboard.
/// With `firstTransportFails` the first transport throws, so the clipboard
/// transport copies. No real microphone, pasteboard, keystrokes or defaults.
@MainActor
private final class PasteLastConcealmentHarness {
    let directory: URL
    let clipboard = WriteMarkRecordingClipboard()
    let transport = TranscriptionCancelTransport()
    let failing = ConcealmentFailingTransport()
    let history: HistoryStore
    let coordinator: SessionCoordinator
    let presenter: WaveformOverlayPresenter
    let controller: DictationController

    init(firstTransportFails: Bool, autoPasteOutcome: AutoPasteOutcome? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoPasteLastConcealment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        history = HistoryStore(
            storageURL: directory.appendingPathComponent("history.json")
        )
        let preferencesStore = AppPreferencesStore(storageURL: directory.appendingPathComponent("preferences.json"))
        let lookup: @Sendable (AppContext) -> Result<EditorTargetHandle, EditorTargetUnavailableReason> = { _ in
            .failure(.unsupportedElement)
        }
        let first: any InsertionTransport = firstTransportFails ? failing : transport
        let clipboardTransport: ClipboardInsertionTransport
        if let autoPasteOutcome {
            // A stand-in for the keystroke: reports an outcome and posts nothing.
            clipboardTransport = ClipboardInsertionTransport(clipboard: clipboard, autoPaste: { _, _ in autoPasteOutcome })
        } else {
            clipboardTransport = ClipboardInsertionTransport(clipboard: clipboard)
        }
        coordinator = SessionCoordinator(
            captureService: TranscriptionCancelCapture(directory: directory),
            transcriptionEngine: ConcealmentUnusedEngine(),
            cleanupEngine: RuleBasedCleanupEngine(),
            insertionService: InsertionService(transports: [
                first,
                clipboardTransport,
            ]),
            historyStore: history,
            lexiconService: PersonalLexiconService(entries: []),
            styleProfileService: StyleProfileService(),
            editorTargetCapture: lookup
        )
        presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.hostedEvidencePrepareOffscreen()
        controller = DictationController(
            hotkey: TranscriptionCancelHotkey(),
            clipboardService: clipboard,
            overlay: presenter,
            mediaInterruption: IsolatedTestMediaService(),
            preferencesStore: preferencesStore,
            coordinator: coordinator,
            runtimeRebuildOverride: { nil },
            overlayDismissDelay: { try? await Task.sleep(for: .seconds(60)) },
            historyStore: history,
            usageAnalyticsStore: UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json")),
            legacyHistoryURL: directory.appendingPathComponent("legacy.json"),
            systemIntegrationsEnabled: false,
            appContextProvider: { AppContext(bundleIdentifier: "com.example.steno-test-editor", appName: "Test Editor") },
            targetDisplayPointProvider: { CGPoint(x: 400, y: 300) }
        )
    }

    func finish() async {
        await controller.teardownAndWait()
        await coordinator.shutdown()
    }

    func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }
}
