import AppKit
import Foundation
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Fix and Undo in a dictation's reader, pressed again before the first press has returned.
@Suite("Fix a Word repeated presses", .serialized)
@MainActor
struct WordFixRepeatedPressTests {
    typealias F = TransitionFixtures

    private func host(_ controller: DictationController, selected: UUID? = nil) -> TransitionHost {
        let feedback = GroveFeedback()
        feedback.announce = { _ in }
        return TransitionHost(controller: controller) {
            GroveRenderHarness.window(.history, controller: controller, feedback: feedback) {
                GroveHistoryView(initialSelectedEntryID: selected)
            }
        }
    }

    private func readerText(_ host: TransitionHost) -> String? {
        host.transcriptViews().first?.textStorage?.string
    }

    /// Opens the Fix a Word form on the first whole `word` in the reader and types `replacement`.
    private func openFixForm(_ host: TransitionHost, word: String, replacement: String) async throws {
        try await host.press("Fix a Word")
        let view = try #require(host.transcriptViews().first)
        try #require(await host.settle { (view.delegate as? TranscriptTextView.Coordinator)?.picksWord == true })
        view.setSelectedRange(((view.textStorage?.string ?? "") as NSString).range(of: word))
        try #require(await host.settle { host.popoverWindows.contains { $0.contentView != nil } }, "no popover")
        try await host.type(replacement, into: "Correct spelling")
    }

    @Test(
        "Pressing Fix twice before the first fix returns makes one fix, not two",
        arguments: [false, true]
    )
    func doubleFixMakesOneFix(yieldsBetweenPresses: Bool) async throws {
        let entry = F.entry("Dana met Dana.")
        let session = try await WindowDictation.make(entries: [entry])
        defer { Task { await session.close() } }
        let host = host(session.controller, selected: entry.id)
        defer { host.close() }
        try #require(await host.settle { readerText(host)?.contains("Dana met Dana") == true }, "the reader says \(readerText(host) ?? "nothing")")

        try await openFixForm(host, word: "Dana", replacement: "Danna")
        let before = try #require(await session.history.recent(limit: 10).first { $0.id == entry.id })
        try #require(before.fixes == nil, "probe: nothing is fixed yet")
        let fix = try #require(host.node(named: "Fix"), "no Fix button: \(host.names())")

        // Two activations before the first apply has returned: in one main-actor turn, or with
        // one yield between them so the first apply has started and is waiting on History.
        let first = fix.press()
        if yieldsBetweenPresses { await Task.yield() }
        // The second press may find the button already disabled; either way it makes no second change.
        _ = fix.press()
        try #require(first, "probe: the first press reached the button")

        try #require(await host.settle { host.node(named: "Copy Corrected Text") != nil }, "the fix never finished: \(host.names())")
        for _ in 0..<25 { await host.pump(.milliseconds(20)) }

        let stored = try #require(await session.history.recent(limit: 10).first { $0.id == entry.id })
        try #require(stored.fixes?.first?.replacement == "Danna", "probe: the fix really ran: \(String(describing: stored.fixes))")
        #expect(stored.cleanText == "Danna met Dana.", "the text is \(stored.cleanText)")
        #expect(stored.fixes?.count == 1, "fixes: \(String(describing: stored.fixes))")
    }

    @Test(
        "Pressing Undo twice before the first Undo returns reverts only the newest fix",
        arguments: [false, true]
    )
    func doubleUndoRevertsOnlyTheNewestFix(yieldsBetweenPresses: Bool) async throws {
        let entry = F.entry("Dana met Bryan.")
        let session = try await WindowDictation.make(entries: [entry])
        defer { Task { await session.close() } }

        // Fix A, made earlier.
        _ = try await session.controller.applyWordFix(
            entryID: entry.id, original: "Dana", occurrence: 0, replacement: "Danna", appliesToFuture: false
        )
        let host = host(session.controller, selected: entry.id)
        defer { host.close() }
        try #require(await host.settle { readerText(host)?.contains("Danna met Bryan") == true }, "the reader says \(readerText(host) ?? "nothing")")

        // Fix B, made in this view, so the note offers Undo.
        try await openFixForm(host, word: "Bryan", replacement: "Brian")
        try await host.press("Fix")
        try #require(await host.settle { host.node(named: "Undo") != nil }, "no Undo: \(host.names())")
        let both = try #require(await session.history.recent(limit: 10).first { $0.id == entry.id })
        try #require(both.cleanText == "Danna met Brian.", "probe: both fixes are in: \(both.cleanText)")
        try #require(both.fixes?.count == 2)

        // Two Undo activations before the first has returned (see the Fix test).
        let undo = try #require(host.node(named: "Undo"))
        let first = undo.press()
        if yieldsBetweenPresses { await Task.yield() }
        // The second press may find the button already disabled; either way it makes no second change.
        _ = undo.press()
        try #require(first, "probe: the first press reached the button")

        try #require(await host.settle { host.node(named: "Undo") == nil }, "Undo never finished")
        for _ in 0..<25 { await host.pump(.milliseconds(20)) }

        let stored = try #require(await session.history.recent(limit: 10).first { $0.id == entry.id })
        try #require(stored.cleanText != "Danna met Brian.", "probe: Undo really ran")
        #expect(stored.cleanText == "Danna met Bryan.", "the text is \(stored.cleanText)")
        #expect(stored.fixes?.count == 1, "fixes: \(String(describing: stored.fixes))")
    }
}
