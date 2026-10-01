import Foundation
import StenoKitTestSupport
import Testing
@testable import StenoKit

/// One app's services, wired the way DictationController builds them, sharing a History file
/// between live dictation and "Run cleanup again".
private struct RerunFixture {
    let historyURL: URL
    let history: HistoryStore
    let lexicon: PersonalLexiconService
    let styles: StyleProfileService
    let snippets: SnippetService

    init(
        entries: [LexiconEntry] = defaultVocabularyEntries,
        globalProfile: StyleProfile = defaultStyleProfile,
        snippets: [Snippet] = []
    ) {
        historyURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rerun-history-\(UUID().uuidString).json")
        history = HistoryStore(storageURL: historyURL, clipboardService: MemoryClipboardService())
        lexicon = PersonalLexiconService(entries: entries)
        styles = StyleProfileService(globalProfile: globalProfile, appProfiles: [:])
        self.snippets = SnippetService(snippets: snippets)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: historyURL)
        let directory = historyURL.deletingLastPathComponent()
        let name = historyURL.lastPathComponent
        for file in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where file.hasPrefix(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    /// Dictates `text` live in the app and returns the History entry it saved.
    func dictate(_ text: String, bundleID: String, appName: String) async throws -> TranscriptEntry {
        let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rerun-\(UUID().uuidString).wav")
        try Data().write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let raw = dictatedTranscript(text)
        let coordinator = SessionCoordinator(
            captureService: StubAudioCaptureService(queuedAudioURLs: [audioURL]),
            transcriptionEngine: StaticTranscriptionEngine { _, _ in raw },
            cleanupEngine: RuleBasedCleanupEngine(),
            insertionService: InsertionService(transports: [
                ClosureInsertionTransport(method: .direct) { _, _ in }
            ]),
            historyStore: history,
            lexiconService: lexicon,
            styleProfileService: styles,
            snippetService: snippets,
            fallbackCleanupEngine: RuleBasedCleanupEngine(),
            editorTargetCapture: { _ in .failure(.unsupportedElement) }
        )
        let context = AppContext.classified(bundleIdentifier: bundleID, appName: appName)
        let sessionID = try await coordinator.startPressToTalk(appContext: context)
        _ = try await coordinator.stopPressToTalk(sessionID: sessionID)
        return try #require(await history.recent(limit: 1).first)
    }

    /// Runs "Run cleanup again" the way DictationController does.
    @discardableResult
    func rerun(_ entry: TranscriptEntry) async throws -> CleanTranscript {
        let context = AppContext.classified(bundleIdentifier: entry.appBundleID, appName: "")
        return try await history.retry(
            entryID: entry.id,
            using: RuleBasedCleanupEngine(),
            profile: await styles.resolve(for: context),
            lexicon: await lexicon.snapshot(for: context),
            appContext: context,
            snippets: snippets
        )
    }

    func stored(_ entry: TranscriptEntry) async throws -> TranscriptEntry {
        try #require(await history.recent(limit: 100).first { $0.id == entry.id })
    }
}

@Test("Re-running cleanup in VS Code, a JetBrains IDE and Warp gives the live text")
func rerunMatchesLiveForIDEsAndTerminals() async throws {
    let apps = [
        ("com.microsoft.VSCode", "Code"),
        ("com.jetbrains.intellij", "IntelliJ IDEA"),
        ("dev.warp.Warp-Stable", "Warp"),
        ("com.citrix.receiver.nomas", "Citrix Workspace"),
        ("com.apple.Notes", "Notes"),
    ]
    let dictations = ["npm install foo", "git status then git push", "/build target", "open stenoh in steno kit"]
    for (bundleID, name) in apps {
        for text in dictations {
            let fixture = RerunFixture()
            defer { fixture.cleanUp() }
            let live = try await fixture.dictate(text, bundleID: bundleID, appName: name)
            try await fixture.rerun(live)
            #expect(try await fixture.stored(live).cleanText == live.cleanText, "\(bundleID): \(text)")
        }
    }
}

@Test("A re-run keeps the first cleaned text, and it can be restored")
func rerunKeepsOriginalForRestore() async throws {
    let fixture = RerunFixture()
    defer { fixture.cleanUp() }
    let live = try await fixture.dictate("ship the gizmo build today", bundleID: "com.apple.Notes", appName: "Notes")
    #expect(live.cleanText == "Ship the gizmo build today")
    #expect(live.originalCleanText == nil)

    await fixture.lexicon.upsert(term: "gizmo", preferred: "Gizmo", scope: .global)
    try await fixture.rerun(live)
    var stored = try await fixture.stored(live)
    #expect(stored.cleanText == "Ship the Gizmo build today")
    #expect(stored.originalCleanText == "Ship the gizmo build today")

    await fixture.lexicon.upsert(term: "build", preferred: "BUILD", scope: .global)
    try await fixture.rerun(live)
    stored = try await fixture.stored(live)
    #expect(stored.cleanText == "Ship the Gizmo BUILD today")
    #expect(stored.originalCleanText == "Ship the gizmo build today")

    let restored = try await fixture.history.restoreOriginalCleanText(entryID: live.id)
    #expect(restored?.cleanText == "Ship the gizmo build today")
    stored = try await fixture.stored(live)
    #expect(stored.cleanText == "Ship the gizmo build today")
    #expect(stored.originalCleanText == nil)
}

@Test("A re-run that gives the original text back leaves nothing to restore")
func rerunBackToOriginalClearsRestore() async throws {
    let fixture = RerunFixture()
    defer { fixture.cleanUp() }
    let live = try await fixture.dictate("ship the gizmo build today", bundleID: "com.apple.Notes", appName: "Notes")
    await fixture.lexicon.upsert(term: "gizmo", preferred: "Gizmo", scope: .global)
    try await fixture.rerun(live)
    await fixture.lexicon.remove(term: "gizmo", scope: .global)
    try await fixture.rerun(live)

    let stored = try await fixture.stored(live)
    #expect(stored.cleanText == live.cleanText)
    #expect(stored.originalCleanText == nil)
}

@Test("Re-running a dictation that used a spoken lowercase directive doesn't add the directive word")
func rerunReplaysDirectives() async throws {
    let fixture = RerunFixture(snippets: [Snippet(trigger: "brb", expansion: "Be right back")])
    defer { fixture.cleanUp() }
    let cases = [
        ("lowercase hello there", "hello there"),
        ("literal lowercase Foo Bar", "lowercase Foo Bar"),
        ("lowercase iPhone sales are up", "iPhone sales are up"),
        ("lowercase brb at noon", "be right back at noon"),
    ]
    for (spoken, expected) in cases {
        let live = try await fixture.dictate(spoken, bundleID: "com.apple.Notes", appName: "Notes")
        #expect(live.cleanText == expected)
        try await fixture.rerun(live)
        let stored = try await fixture.stored(live)
        #expect(stored.cleanText == expected, "\(spoken)")
        #expect(stored.originalCleanText == nil)
    }
}

@Test("An older entry whose directive History can't replay is left unchanged")
func rerunLeavesUnreplayableDirectiveAlone() async throws {
    let fixture = RerunFixture()
    defer { fixture.cleanUp() }
    // Saved by a version without spoken directives, or already re-run by 1.0.0, which put the
    // directive word back.
    let older = TranscriptEntry(
        appBundleID: "com.apple.Notes",
        rawText: "lowercase hello there",
        cleanText: "Lowercase hello there",
        audioURL: nil,
        insertionStatus: .inserted
    )
    try await fixture.history.append(entry: older)

    await #expect(throws: HistoryStoreError.directiveCannotBeReplayed) {
        try await fixture.rerun(older)
    }
    let stored = try await fixture.stored(older)
    #expect(stored.cleanText == "Lowercase hello there")
    #expect(stored.originalCleanText == nil)
}

@Test("A re-run that would leave no text is not saved")
func rerunThatEmptiesTextIsNotSaved() async throws {
    let fixture = RerunFixture(globalProfile: StyleProfile(
        name: "Aggressive",
        tone: .natural,
        structureMode: .paragraph,
        fillerPolicy: .aggressive,
        commandPolicy: .transform
    ))
    defer { fixture.cleanUp() }
    let entry = TranscriptEntry(
        appBundleID: "com.apple.Notes",
        rawText: "Um, uh.",
        cleanText: "Um, uh.",
        audioURL: nil,
        insertionStatus: .inserted
    )
    try await fixture.history.append(entry: entry)

    await #expect(throws: HistoryStoreError.rerunLeftNoText) {
        try await fixture.rerun(entry)
    }
    #expect(try await fixture.stored(entry).cleanText == "Um, uh.")
}

@Test("History with a kept original decodes with the 1.0.0 types")
func historyWithOriginalDecodesInReleasedVersion() async throws {
    let fixture = RerunFixture()
    defer { fixture.cleanUp() }
    let live = try await fixture.dictate("ship the gizmo build today", bundleID: "com.apple.Notes", appName: "Notes")
    await fixture.lexicon.upsert(term: "gizmo", preferred: "Gizmo", scope: .global)
    try await fixture.rerun(live)

    let released = try Released100.decoder().decode(
        [Released100.TranscriptEntry].self,
        from: Data(contentsOf: fixture.historyURL)
    )
    #expect(released.map(\.cleanText) == ["Ship the Gizmo build today"])

    let reloaded = HistoryStore(storageURL: fixture.historyURL, clipboardService: MemoryClipboardService())
    #expect(await reloaded.recent(limit: 1).first?.originalCleanText == "Ship the gizmo build today")
    #expect(await reloaded.takeRecoveryNotices().isEmpty)
}
