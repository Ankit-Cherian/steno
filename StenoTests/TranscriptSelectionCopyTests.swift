import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Copying words selected in a saved dictation (Edit > Copy, a drag, a Service) writes the
/// dictation's stored text for that range, never the characters the reader substitutes for
/// drawing, and writes it concealed when the dictation was meant for a password field.
/// Every write goes to a private named pasteboard, never the general one.
@Suite("Copying selected dictation text", .serialized)
@MainActor
struct TranscriptSelectionCopyTests {
    typealias F = TransitionFixtures

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private func history(_ entry: TranscriptEntry) -> TransitionHost {
        let controller = F.sampleController([entry])
        return TransitionHost(controller: controller) {
            GroveRenderHarness.window(.history, controller: controller) { GroveHistoryView(initialSelectedEntryID: entry.id) }
        }
    }

    private func today(_ entry: TranscriptEntry) -> TransitionHost {
        let controller = F.sampleController([entry])
        return TransitionHost(controller: controller) {
            GroveRenderHarness.window(.today, controller: controller) { GroveTodayView() }
        }
    }

    private func withPrivatePasteboard<T>(_ body: (NSPasteboard) throws -> T) rethrows -> T {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("steno-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        return try body(pasteboard)
    }

    /// What copying `range` of the text view's selection writes to a private pasteboard: its
    /// string and its types.
    private func copied(_ range: NSRange, from view: TranscriptNSTextView) -> (string: String?, types: [NSPasteboard.PasteboardType], wrote: Bool) {
        view.setSelectedRange(range)
        return withPrivatePasteboard { pasteboard in
            // What Edit > Copy does: declare the view's writable types, then have it write them.
            let types = view.writablePasteboardTypes
            pasteboard.declareTypes(types, owner: nil)
            let wrote = view.writeSelection(to: pasteboard, types: types)
            return (pasteboard.string(forType: .string), pasteboard.types ?? [], wrote)
        }
    }

    // MARK: Stored text

    @Test("Copying a selection that includes the last space writes a plain space, in History and on Today")
    func selectionIncludingTheLastSpaceCopiesAPlainSpace() async throws {
        let stored = "Send the slides to Dana on Friday afternoon."
        let entry = F.entry(stored)
        for page in ["History", "Today"] {
            let host = page == "History" ? history(entry) : today(entry)
            defer { host.close() }
            #expect(await host.settle { host.transcriptViews().first != nil }, "\(page) drew no words")
            let view = try #require(host.transcriptViews().first)
            // Setup precondition: the reader draws a no-break space where the stored text has a space.
            try #require(view.textStorage?.string.contains("\u{00A0}") == true)

            let all = copied(NSRange(location: 0, length: (stored as NSString).length), from: view)
            #expect(all.wrote)
            #expect(all.string == stored, "\(page): select all copied \(String(describing: all.string?.debugDescription))")

            let spanning = (stored as NSString).range(of: "Friday afternoon.")
            let span = copied(NSRange(location: spanning.location - 3, length: spanning.length + 3), from: view)
            #expect(span.string == "on Friday afternoon.", "\(page): a range over the last space copied \(String(describing: span.string?.debugDescription))")
        }
    }

    @Test("Copying a dictation padded with blank lines writes the stored blank lines, not zero-width spaces")
    func paddedDictationCopiesItsStoredWhitespace() async throws {
        let stored = WindowSampleData.padded
        let entry = F.entry(stored)
        let host = history(entry)
        defer { host.close() }
        #expect(await host.settle { host.transcriptViews().first != nil })
        let view = try #require(host.transcriptViews().first)
        try #require(view.textStorage?.string.contains("\u{200B}") == true)

        let all = copied(NSRange(location: 0, length: (stored as NSString).length), from: view)
        #expect(all.string == stored, "copied \(String(describing: all.string?.debugDescription))")
        let edge = copied(NSRange(location: 0, length: 6), from: view)
        #expect(edge.string == (stored as NSString).substring(with: NSRange(location: 0, length: 6)))
    }

    @Test("Control: a selection that holds no substituted character copies exactly as before")
    func plainSelectionCopiesItsWords() async throws {
        let stored = "Send the slides to Dana on Friday afternoon."
        let host = history(F.entry(stored))
        defer { host.close() }
        #expect(await host.settle { host.transcriptViews().first != nil })
        let view = try #require(host.transcriptViews().first)
        let range = (stored as NSString).range(of: "the slides to Dana")
        let result = copied(range, from: view)
        #expect(result.wrote)
        #expect(result.string == "the slides to Dana")
        #expect(!result.types.contains(Self.concealedType), "types were \(result.types)")
    }

    // MARK: Concealed

    @Test("Copying words selected in a password-field dictation is written concealed, in History and on Today")
    func selectionOfAConcealedDictationIsConcealed() async throws {
        let stored = "Hunter two is the password for the staging server."
        var entry = F.entry(stored, status: .copiedOnly)
        entry.concealedCopy = true
        for page in ["History", "Today"] {
            let host = page == "History" ? history(entry) : today(entry)
            defer { host.close() }
            #expect(await host.settle { host.transcriptViews().first != nil }, "\(page) drew no words")
            let view = try #require(host.transcriptViews().first)
            let result = copied(NSRange(location: 0, length: (stored as NSString).length), from: view)
            #expect(result.wrote)
            #expect(result.string == stored)
            #expect(result.types.contains(Self.concealedType), "\(page): types were \(result.types)")
        }
    }

    @Test("Control: words selected in an ordinary dictation are not marked concealed")
    func selectionOfAnOrdinaryDictationIsNotConcealed() async throws {
        let stored = "Send the slides to Dana on Friday afternoon."
        let host = history(F.entry(stored))
        defer { host.close() }
        #expect(await host.settle { host.transcriptViews().first != nil })
        let view = try #require(host.transcriptViews().first)
        let result = copied(NSRange(location: 0, length: (stored as NSString).length), from: view)
        #expect(!result.types.contains(Self.concealedType), "types were \(result.types)")
    }
}
