import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// The menu bar panel's own items run on a real controller: Dictate and Stop, Discard and Undo
/// Discard, Paste Last Dictation and Copy Last Dictation. The panel is opened as a click on the
/// status item opens it, without putting an item in the menu bar.
@Suite("Menu flow transitions", .serialized)
@MainActor
struct MenuFlowTransitionTests {
    private func menu(for controller: DictationController) -> (MenuBarController, () -> GroveMenuPresenter?) {
        var made: GroveMenuPresenter?
        let menu = MenuBarController(makePanelPresenter: {
            let presenter = GroveMenuPresenter(installsMonitors: false, reducesTransparency: { false },
                                               present: { panel in
                                                   panel.alphaValue = 0
                                                   panel.ignoresMouseEvents = true
                                                   panel.orderFrontRegardless()
                                               },
                                               dismiss: { $0.orderOut(nil) })
            made = presenter
            return presenter
        })
        menu.observeInputLevel(of: controller)
        return (menu, { made })
    }

    /// Opens the panel as a click on the status item does, and returns what VoiceOver reads.
    private func open(_ menu: MenuBarController, _ presenter: () -> GroveMenuPresenter?) async throws
        -> (status: String, items: [NSAccessibilityElement]) {
        if presenter()?.isShown == true { menu.toggleGrovePanel(keyboardInitiated: false) }
        menu.toggleGrovePanel(keyboardInitiated: false)
        _ = await eventuallyOnMain {
            let children = presenter()?.panel.contentView?.accessibilityChildren() ?? []
            return presenter()?.isShown == true && children.count > 1
        }
        let panel = try #require(presenter()?.panel)
        let children = panel.contentView?.accessibilityChildren() ?? []
        let status = (children.first as? NSAccessibilityElement)?.accessibilityLabel() ?? ""
        return (status, children.dropFirst().compactMap { $0 as? NSAccessibilityElement })
    }

    private func press(_ label: String, in menu: MenuBarController, _ presenter: () -> GroveMenuPresenter?,
                       sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let read = try await open(menu, presenter)
        let item = try #require(read.items.first { $0.accessibilityLabel() == label },
                                "no “\(label)” in \(read.items.compactMap { $0.accessibilityLabel() })", sourceLocation: sourceLocation)
        #expect(item.accessibilityPerformPress(), sourceLocation: sourceLocation)
        #expect(presenter()?.isShown == false, "the panel stayed open after \(label)", sourceLocation: sourceLocation)
    }

    private func until(_ condition: @MainActor () async -> Bool) async -> Bool {
        await eventuallyOnMain(condition)
    }

    @Test("Dictate starts a hands-free dictation, the panel then says Listening, and Stop ends it with the words as latest")
    func dictateAndStop() async throws {
        let session = try await WindowDictation.make(outcome: .init(text: "Ship the slides at noon.", status: .inserted))
        defer { Task { await session.close() } }
        let (menu, presenter) = menu(for: session.controller)
        defer { presenter()?.close() }

        try await press("Dictate", in: menu, presenter)
        #expect(await until { session.controller.recordingLifecycleState == .recordingHandsFree }, "Dictate did not start")
        // Stop only once capture has reached the coordinator, as a person's later Stop would.
        #expect(await until { await session.coordinator.count("start") == 1 })
        let listening = try await open(menu, presenter)
        #expect(listening.status.hasPrefix("Listening, "), "status: \(listening.status)")
        try await press("Stop and insert", in: menu, presenter)
        #expect(await until { session.controller.recentEntries.first?.cleanText == "Ship the slides at noon." })
        let after = try await open(menu, presenter)
        #expect(after.items.contains { $0.accessibilityLabel() == "Dictate" })
        #expect(after.items.contains { ($0.accessibilityLabel() ?? "").contains("Copy") }, "the result cannot be reached")
    }

    @Test("Stop pressed straight after Dictate, before capture has started, still ends the dictation with its words")
    func stopStraightAfterDictate() async throws {
        let session = try await WindowDictation.make(outcome: .init(text: "Call the vendor back.", status: .inserted))
        defer { Task { await session.close() } }
        let (menu, presenter) = menu(for: session.controller)
        defer { presenter()?.close() }

        try await press("Dictate", in: menu, presenter)
        try await press("Stop and insert", in: menu, presenter)
        #expect(await until { session.controller.recentEntries.first?.cleanText == "Call the vendor back." },
                "status: \(session.controller.status)")
        #expect(await until { session.controller.recordingLifecycleState == .idle })
        #expect(!session.controller.isRecording)
        #expect(await session.coordinator.count("start") == 1)
        #expect(await session.coordinator.count("transcribe") == 1)
        #expect(await session.coordinator.count("cancel") == 0)
    }

    @Test("Discard throws a long recording away, and Undo Discard brings it back and inserts it once")
    func discardAndUndo() async throws {
        let session = try await WindowDictation.make(outcome: .init(text: "Keep the draft.", status: .inserted))
        defer { Task { await session.close() } }
        session.controller.undoDiscardMinimumRecording = 0
        let (menu, presenter) = menu(for: session.controller)
        defer { presenter()?.close() }

        try await press("Dictate", in: menu, presenter)
        #expect(await until { session.controller.isRecording })
        #expect(await until { await session.coordinator.count("start") == 1 })
        try await press("Discard", in: menu, presenter)
        #expect(await until { session.controller.canUndoDiscard }, "no Undo after Discard")
        #expect(session.controller.recentEntries.isEmpty)
        try await press("Undo Discard", in: menu, presenter)
        #expect(await until { session.controller.recentEntries.first?.cleanText == "Keep the draft." }, "Undo inserted nothing")
        #expect(await session.coordinator.count("transcribe") == 1)
    }

    @Test("Paste Last Dictation inserts the newest dictation once, and Copy Last Dictation copies it")
    func pasteAndCopyLast() async throws {
        let latest = TransitionFixtures.entry("Meet at the north entrance.")
        let session = try await WindowDictation.make(entries: [latest, TransitionFixtures.entry("Older words.", minutesAgo: 5)])
        defer { Task { await session.close() } }
        let (menu, presenter) = menu(for: session.controller)
        defer { presenter()?.close() }

        try await press("Paste Last Dictation", in: menu, presenter)
        let pasted = await until { await session.coordinator.events.contains("insert: Meet at the north entrance.") }
        let events = await session.coordinator.events
        #expect(pasted, "events: \(events)")
        #expect(await session.coordinator.events.filter { $0.hasPrefix("insert: ") }.count == 1)

        try await press("Copy Last Dictation", in: menu, presenter)
        let copied = await until { await session.clipboard.latestValue == "Meet at the north entrance." }
        let clipboard = await session.clipboard.latestValue
        #expect(copied, "clipboard: \(clipboard)")
    }
}
