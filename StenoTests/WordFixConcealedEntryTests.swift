import AppKit
import Foundation
import StenoKit
import Testing
@testable import Steno

@MainActor
private final class ConcealedFixHotkey: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16?

    func start() {}
    func stop() {}
}

/// Fix a Word on a dictation copied from a password field: its words never reach Word
/// Corrections, the lexicon or recognition prompts.
@Suite("Fix a Word on a password-field dictation", .serialized)
@MainActor
struct WordFixConcealedEntryTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoWordFixConcealed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Asking the controller for a future fix on a password-field dictation is refused and saves no correction")
    func controllerRefusesFutureFixOnConcealedEntry() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferencesURL = directory.appendingPathComponent("preferences.json")
        let history = HistoryStore(storageURL: directory.appendingPathComponent("history.json"))
        let entry = TranscriptEntry(
            appBundleID: "com.apple.Safari", rawText: "hunter twoo",
            cleanText: "Hunter twoo", audioURL: nil, insertionStatus: .copiedOnly, concealedCopy: true
        )
        try await history.append(entry: entry)
        let store = AppPreferencesStore(storageURL: preferencesURL)
        _ = await store.save(.default)
        let controller = makeTestDictationController(
            hotkey: ConcealedFixHotkey(),
            preferencesStore: store,
            historyStore: history,
            legacyHistoryURL: directory.appendingPathComponent("legacy.json")
        )
        defer { controller.teardown() }
        controller.preferences = await store.load()
        await controller.refreshHistory()
        let correctionsBefore = controller.preferences.lexiconEntries

        await #expect(throws: WordFixError.concealedDictation) {
            try await controller.applyWordFix(
                entryID: entry.id, original: "twoo", occurrence: 0,
                replacement: "two", appliesToFuture: true, confirmingCommonWord: true
            )
        }

        #expect(controller.preferences.lexiconEntries == correctionsBefore)
        #expect(await AppPreferencesStore(storageURL: preferencesURL).load().lexiconEntries == correctionsBefore)
        #expect(!controller.preferences.lexiconEntries.contains { $0.term == "twoo" || $0.preferred == "two" })
        let stored = await history.recent(limit: 10).first { $0.id == entry.id }
        #expect(stored?.cleanText == "Hunter twoo")
        #expect(stored?.fixes == nil)
    }

    @Test("Fix a Word offers only Just this dictation for a password-field dictation")
    func concealedEntryOffersThisDictationOnly() {
        var entry = TranscriptEntry(
            appBundleID: "com.apple.Safari", rawText: "hunter twoo",
            cleanText: "Hunter twoo", audioURL: nil, insertionStatus: .copiedOnly
        )
        #expect(FixWordState.Scope.offered(for: entry) == [.thisDictation, .future])
        entry.concealedCopy = true
        #expect(FixWordState.Scope.offered(for: entry) == [.thisDictation])
        #expect(FixWordState.Scope.offered(for: entry).map(\.title) == ["Just this dictation"])
    }

    @Test("History's Fix a Word popover for a password-field dictation has no future option")
    func concealedEntryPopoverHasNoFutureOption() async throws {
        var entry = TransitionFixtures.entry("Hunter twoo", status: .copiedOnly)
        entry.concealedCopy = true
        let controller = TransitionFixtures.sampleController([entry])
        let host = TransitionHost(size: GroveRenderHarness.minimumSize, controller: controller, knobs: TransitionKnobs()) {
            GroveRenderHarness.window(.history, controller: controller) { GroveHistoryView(initialSelectedEntryID: entry.id) }
        }
        defer { host.close() }
        #expect(await host.settle { host.transcriptViews().first != nil }, "no text")
        try await host.press("Fix a Word")
        let view = try #require(host.transcriptViews().first)
        #expect(await host.settle { (view.delegate as? TranscriptTextView.Coordinator)?.picksWord == true })
        let range = ((view.textStorage?.string ?? "") as NSString).range(of: "twoo")
        try #require(range.location != NSNotFound)
        view.setSelectedRange(range)
        #expect(await host.settle { host.node(named: "Just this dictation") != nil }, "no form")
        let popover = try #require(host.popoverWindows.last, "no popover window")
        let inPopover = host.nodes().filter { popover.frame.intersects($0.screenFrame) }
        #expect(inPopover.contains { $0.name == "Just this dictation" || $0.text == "Just this dictation" })
        #expect(!inPopover.contains { $0.name == "This and future dictations" || $0.text == "This and future dictations" },
                "\(inPopover.map { "\($0.role) \($0.name)|\($0.text)" })")
        #expect(!inPopover.contains { $0.text.contains("Word Corrections") || $0.name.contains("Word Corrections") })
    }
}
