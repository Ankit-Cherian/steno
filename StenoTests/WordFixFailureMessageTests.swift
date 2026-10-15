import AppKit
import Foundation
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// A Fix a Word that cannot be made says so, rather than closing the form without a word.
@Suite("Fix a Word failure message", .serialized)
@MainActor
struct WordFixFailureMessageTests {
    typealias F = TransitionFixtures

    private func readerText(_ host: TransitionHost) -> String? {
        host.transcriptViews().first?.textStorage?.string
    }

    @Test("A fix that fails shows a message the window announces")
    func failedFixShowsAMessage() async throws {
        let entry = F.entry("Dana met Bryan.")
        let session = try await WindowDictation.make(entries: [entry])
        defer { Task { await session.close() } }
        let feedback = GroveFeedback()
        var announced: [String] = []
        feedback.announce = { announced.append($0) }
        let host = TransitionHost(controller: session.controller) {
            GroveRenderHarness.window(.history, controller: session.controller, feedback: feedback) {
                GroveHistoryView(initialSelectedEntryID: entry.id)
            }
        }
        defer { host.close() }
        try #require(await host.settle { readerText(host)?.contains("Dana met Bryan") == true })

        try await host.press("Fix a Word")
        let view = try #require(host.transcriptViews().first)
        try #require(await host.settle { (view.delegate as? TranscriptTextView.Coordinator)?.picksWord == true })
        view.setSelectedRange(((view.textStorage?.string ?? "") as NSString).range(of: "Bryan"))
        try #require(await host.settle { host.popoverWindows.contains { $0.contentView != nil } }, "no popover")
        try await host.type("Brian", into: "Correct spelling")

        // The dictation is deleted from another window while the form is open, so History
        // cannot make the fix.
        try await session.history.delete(entryID: entry.id)
        try #require(feedback.notice == nil, "probe: nothing is shown yet")

        try await host.press("Fix")
        try #require(await host.settle { feedback.notice != nil }, "nothing was said: \(host.names())")
        let message = try #require(feedback.notice?.text)
        #expect(!message.isEmpty)
        #expect(feedback.notice?.tone == .caution)
        #expect(announced == [message], "VoiceOver heard \(announced)")
    }

    /// The reader on `entry` in a History whose folder can be made read-only, so a write fails.
    private func readerOnUnwritableHistory(_ entry: TranscriptEntry, feedback: GroveFeedback)
        async throws -> (session: WindowDictation, host: TransitionHost) {
        let session = try await WindowDictation.make(entries: [entry])
        let host = TransitionHost(controller: session.controller) {
            GroveRenderHarness.window(.history, controller: session.controller, feedback: feedback) {
                GroveHistoryView(initialSelectedEntryID: entry.id)
            }
        }
        try #require(await host.settle { readerText(host)?.contains("Dana met Bryan") == true })
        return (session, host)
    }

    private func fixBryan(as correction: String, in host: TransitionHost) async throws {
        try await host.press("Fix a Word")
        let view = try #require(host.transcriptViews().first)
        try #require(await host.settle { (view.delegate as? TranscriptTextView.Coordinator)?.picksWord == true })
        view.setSelectedRange(((view.textStorage?.string ?? "") as NSString).range(of: "Bryan"))
        try #require(await host.settle { host.popoverWindows.contains { $0.contentView != nil } }, "no popover")
        try await host.type(correction, into: "Correct spelling")
    }

    private func setHistoryFolderWritable(_ writable: Bool, of session: WindowDictation) throws {
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o700 : 0o500], ofItemAtPath: session.directory.path)
    }

    @Test("A fix that History cannot save says so and leaves the words as they were")
    func unsavedFixShowsAMessage() async throws {
        let feedback = GroveFeedback()
        var announced: [String] = []
        feedback.announce = { announced.append($0) }
        let (session, host) = try await readerOnUnwritableHistory(F.entry("Dana met Bryan."), feedback: feedback)
        defer { host.close(); try? setHistoryFolderWritable(true, of: session); Task { await session.close() } }
        try await fixBryan(as: "Brian", in: host)

        try setHistoryFolderWritable(false, of: session)
        try await host.press("Fix")
        try #require(await host.settle { feedback.notice != nil }, "nothing was said: \(host.names())")
        let message = try #require(feedback.notice?.text)
        #expect(message == "Unable to persist transcript history")
        #expect(feedback.notice?.tone == .caution)
        #expect(announced == [message], "VoiceOver heard \(announced)")
        #expect(readerText(host)?.contains("Bryan") == true, "the reader says \(readerText(host) ?? "")")
    }

    @Test("An Undo that History cannot save says so and keeps the fix")
    func unsavedUndoShowsAMessage() async throws {
        let feedback = GroveFeedback()
        var announced: [String] = []
        feedback.announce = { announced.append($0) }
        let (session, host) = try await readerOnUnwritableHistory(F.entry("Dana met Bryan."), feedback: feedback)
        defer { host.close(); try? setHistoryFolderWritable(true, of: session); Task { await session.close() } }
        try await fixBryan(as: "Brian", in: host)
        try await host.press("Fix")
        try #require(await host.settle { readerText(host)?.contains("Brian") == true }, "the fix was not made")
        try #require(await host.settle { host.node(named: "Undo") != nil }, "no Undo: \(host.names())")
        try #require(feedback.notice == nil, "probe: nothing is shown yet")

        try setHistoryFolderWritable(false, of: session)
        try await host.press("Undo")
        try #require(await host.settle { feedback.notice != nil }, "nothing was said: \(host.names())")
        let message = try #require(feedback.notice?.text)
        #expect(message == "Unable to persist transcript history")
        #expect(feedback.notice?.tone == .caution)
        #expect(announced == [message], "VoiceOver heard \(announced)")
        #expect(readerText(host)?.contains("Brian") == true, "the reader says \(readerText(host) ?? "")")
    }
}
