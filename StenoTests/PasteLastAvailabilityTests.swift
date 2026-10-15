import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

@Suite("Paste Last Dictation availability", .serialized)
@MainActor
struct PasteLastAvailabilityTests {
    private static let pasteLabel = "Paste Last Dictation"

    // MARK: - The menu panel, driven the way MenuFlowTransitionTests drives it

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

    private func pasteRow(_ menu: MenuBarController, _ presenter: () -> GroveMenuPresenter?) async throws -> NSAccessibilityElement {
        let read = try await open(menu, presenter)
        return try #require(read.items.first { $0.accessibilityLabel() == Self.pasteLabel },
                            "no “\(Self.pasteLabel)” in \(read.items.compactMap { $0.accessibilityLabel() }); status: \(read.status)")
    }

    @Test("Paste Last Dictation is off in the menu panel while a hands-free dictation is recording")
    func pasteLastDictationIsOffWhileListening() async throws {
        let session = try await WindowDictation.make(entries: [TransitionFixtures.entry("Meet at the north entrance.")])
        defer { Task { await session.close() } }
        let (menu, presenter) = menu(for: session.controller)
        defer { presenter()?.close() }

        // Probe: with nothing in progress the row is on, so a disabled row below comes from the dictation.
        let idleRow = try await pasteRow(menu, presenter)
        try #require(idleRow.isAccessibilityEnabled(), "probe: Paste Last Dictation should be on while idle")

        session.controller.toggleHandsFree()
        try #require(await eventuallyOnMain { session.controller.recordingLifecycleState == .recordingHandsFree }, "Dictate did not start")
        try #require(await eventuallyOnMain { await session.coordinator.count("start") == 1 }, "capture never reached the coordinator")
        try #require(session.controller.isRecording, "probe: recording")

        let row = try await pasteRow(menu, presenter)
        #expect(!row.isAccessibilityEnabled(), "Paste Last Dictation is offered as enabled while Listening")
        #expect(!row.accessibilityPerformPress(), "a press on Paste Last Dictation was accepted while Listening")
        #expect(await session.coordinator.events.filter { $0.hasPrefix("insert: ") }.isEmpty)
    }

    @Test("Paste Last Dictation is off in the menu panel while a dictation is transcribing")
    func pasteLastDictationIsOffWhileTranscribing() async throws {
        let session = try await WindowDictation.make(entries: [TransitionFixtures.entry("Meet at the north entrance.")])
        defer { Task { await session.close() } }
        let (menu, presenter) = menu(for: session.controller)
        defer { presenter()?.close() }

        await session.coordinator.hold()
        session.controller.toggleHandsFree()
        try #require(await eventuallyOnMain { session.controller.recordingLifecycleState == .recordingHandsFree }, "Dictate did not start")
        try #require(await eventuallyOnMain { await session.coordinator.count("start") == 1 }, "capture never reached the coordinator")
        session.controller.stopRecording()
        try #require(await eventuallyOnMain { session.controller.recordingLifecycleState == .transcribing }, "Stop did not reach Transcribing")
        try #require(await eventuallyOnMain { await session.coordinator.count("transcribe") == 1 }, "transcription never began")

        let row = try await pasteRow(menu, presenter)
        #expect(!row.isAccessibilityEnabled(), "Paste Last Dictation is offered as enabled while Transcribing")
        #expect(!row.accessibilityPerformPress(), "a press on Paste Last Dictation was accepted while Transcribing")

        await session.coordinator.release()
        #expect(await eventuallyOnMain { session.controller.recordingLifecycleState == .idle })
        #expect(await session.coordinator.events.filter { $0.hasPrefix("insert: ") }.isEmpty)
    }

    @Test("A Paste Last Dictation refused during a dictation tells the person on the island, not only in the status")
    func refusedPasteLastDuringDictationIsVisible() async throws {
        let session = try await WindowDictation.make(entries: [TransitionFixtures.entry("Meet at the north entrance.")])
        defer { Task { await session.close() } }

        session.controller.toggleHandsFree()
        try #require(await eventuallyOnMain { session.controller.recordingLifecycleState == .recordingHandsFree }, "Dictate did not start")
        try #require(await eventuallyOnMain { await session.coordinator.count("start") == 1 }, "capture never reached the coordinator")
        try await Task.sleep(for: .milliseconds(100))
        let before = session.overlay.hostedEvidenceRequestedStates()

        // The shortcut reaches the controller as the global paste shortcut does.
        let handler = try #require(session.hotkey.onPasteLastShortcut, "the controller wired no paste shortcut")
        handler()
        try await Task.sleep(for: .milliseconds(150))

        try #require(session.controller.status == "Finish the current dictation, then paste the last one.",
                     "probe: the refusal path ran; status: \(session.controller.status)")
        let added = Array(session.overlay.hostedEvidenceRequestedStates().dropFirst(before.count))
        #expect(added == [.busy(.pasteWaitsForDictation)], "the island was asked for \(added)")
        #expect(session.controller.recordingLifecycleState == .recordingHandsFree, "the refusal disturbed the dictation")
        #expect(await session.coordinator.events.filter { $0.hasPrefix("insert: ") }.isEmpty)
    }

    @Test("A Paste Last Dictation refused because the runtime is not ready tells the person on the island, not only in the status")
    func refusedPasteLastWithoutRuntimeIsVisible() async throws {
        let window = try await WindowWithOptionalRuntime.make(coordinator: nil, entries: [TransitionFixtures.entry("Meet at the north entrance.")])
        defer { Task { await window.close() } }
        try await Task.sleep(for: .milliseconds(100))
        let before = window.overlay.hostedEvidenceRequestedStates()

        let handler = try #require(window.hotkey.onPasteLastShortcut, "the controller wired no paste shortcut")
        handler()
        try await Task.sleep(for: .milliseconds(150))

        try #require(window.controller.status == "Runtime not ready yet.", "probe: the refusal path ran; status: \(window.controller.status)")
        let added = Array(window.overlay.hostedEvidenceRequestedStates().dropFirst(before.count))
        #expect(added == [.busy(.modelLoading)], "the island was asked for \(added)")
    }

    @Test("A Paste Last Dictation with nothing to paste tells the person on the island, not only in the status")
    func refusedPasteLastWithNothingToPasteIsVisible() async throws {
        let session = try await WindowDictation.make(entries: [])
        defer { Task { await session.close() } }
        try await Task.sleep(for: .milliseconds(100))
        let before = session.overlay.hostedEvidenceRequestedStates()

        let handler = try #require(session.hotkey.onPasteLastShortcut, "the controller wired no paste shortcut")
        handler()
        try #require(await eventuallyOnMain { session.controller.status == "No dictation to paste yet." },
                     "probe: the refusal path ran; status: \(session.controller.status)")
        try #require(await eventuallyOnMain { session.controller.recordingLifecycleState == .idle })

        let added = Array(session.overlay.hostedEvidenceRequestedStates().dropFirst(before.count))
        #expect(added == [.busy(.nothingToPaste)], "the island was asked for \(added)")
        #expect(await session.coordinator.events.filter { $0.hasPrefix("insert: ") }.isEmpty)
    }

    @Test("A Paste Last Dictation refused while a dictation is transcribing tells the person on the island")
    func refusedPasteLastWhileTranscribingIsVisible() async throws {
        let session = try await WindowDictation.make(entries: [TransitionFixtures.entry("Meet at the north entrance.")])
        defer { Task { await session.close() } }

        await session.coordinator.hold()
        session.controller.toggleHandsFree()
        try #require(await eventuallyOnMain { session.controller.recordingLifecycleState == .recordingHandsFree }, "Dictate did not start")
        try #require(await eventuallyOnMain { await session.coordinator.count("start") == 1 }, "capture never reached the coordinator")
        session.controller.stopRecording()
        try #require(await eventuallyOnMain { await session.coordinator.count("transcribe") == 1 }, "transcription never began")
        let before = session.overlay.hostedEvidenceRequestedStates()

        let handler = try #require(session.hotkey.onPasteLastShortcut, "the controller wired no paste shortcut")
        handler()
        try await Task.sleep(for: .milliseconds(150))

        let added = Array(session.overlay.hostedEvidenceRequestedStates().dropFirst(before.count))
        #expect(added == [.busy(.pasteWaitsForDictation)], "the island was asked for \(added)")
        await session.coordinator.release()
        #expect(await eventuallyOnMain { session.controller.recordingLifecycleState == .idle })
        #expect(await session.coordinator.events.filter { $0.hasPrefix("insert: ") }.isEmpty)
    }
}
