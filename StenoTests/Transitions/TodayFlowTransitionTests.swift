import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Today dictating through its own controls on a real controller: Dictate, Stop, Discard and
/// Undo, Cancel while transcribing, and every note a dictation can end in.
@Suite("Today flow transitions", .serialized)
@MainActor
struct TodayFlowTransitionTests {
    typealias F = TransitionFixtures

    /// A result that never comes is given up on only after a minute, so a slow History refresh
    /// is not mistaken for one. Results and notes stay three seconds, long enough for a busy
    /// main thread to draw them before they go, and short enough to watch them go.
    private static let timing = GroveTodayFlow.Timing(resultWait: .seconds(60), settleHold: .seconds(3), quietNote: .seconds(3))

    private func host(_ controller: DictationController, feedback: GroveFeedback = GroveFeedback(),
                      flow: GroveTodayFlow? = nil) -> TransitionHost {
        let flow = flow ?? GroveTodayFlow(timing: Self.timing)
        feedback.announce = { _ in }
        return TransitionHost(controller: controller) {
            GroveRenderHarness.window(.today, controller: controller, feedback: feedback) { GroveTodayView(flow: flow) }
        }
    }

    private func cardText(_ host: TransitionHost) -> String? {
        host.transcriptViews().first?.textStorage?.string
    }

    private func says(_ host: TransitionHost, _ prefix: String) -> Bool {
        host.node { $0.text.hasPrefix(prefix) } != nil
    }

    @Test("Dictate starts from an empty Today, Stop and copy ends it, and the copied result becomes the first card")
    func dictateFromAnEmptyToday() async throws {
        // Steno's own window has no text field, so a dictation started here is copied.
        let session = try await WindowDictation.make(outcome: .init(text: "Lunch moved to one.", status: .copiedOnly))
        defer { Task { await session.close() } }
        let host = host(session.controller)
        defer { host.close() }
        #expect(await host.settle { says(host, "Nothing dictated yet") }, "no empty state: \(host.names())")

        try await host.press("Dictate")
        #expect(await host.settle { host.node(named: "Stop and copy") != nil }, "not listening: \(host.names())")
        #expect(says(host, "Listening"))
        #expect(host.node(identifier: "today.start") == nil)
        #expect(await session.coordinator.count("start") == 1)

        try await host.press("Stop and copy")
        #expect(await host.settle { says(host, "Copied") }, "no copied result: \(host.names())")
        #expect(await host.settle { cardText(host) == GroveFlowText.displayText("Lunch moved to one.") }, "the card shows \(cardText(host) ?? "nothing")")
        #expect(await host.settle { host.node(identifier: "today.start") != nil }, "the stage never came back")
        #expect(!says(host, "Nothing dictated yet"), "the empty note stayed with a dictation on the page")
        #expect(await session.coordinator.count("transcribe") == 1)
    }

    @Test("Space starts a dictation and stops it, from the keyboard alone")
    func spaceStartsAndStops() async throws {
        let session = try await WindowDictation.make()
        defer { Task { await session.close() } }
        let host = host(session.controller)
        defer { host.close() }
        await host.settle { host.node(identifier: "today.start") != nil }

        // Space starts the stage from the stage: Tab with Full Keyboard Access puts the focus there.
        host.moveKeyboardFocus(to: try #require(host.node(identifier: "today.start")))
        await host.settle()
        await host.keyPress(49, characters: " ")
        #expect(await host.settle { host.node(named: "Stop and copy") != nil }, "Space did not start: \(host.names())")
        await host.keyPress(49, characters: " ")
        #expect(await host.settle { cardText(host) == GroveFlowText.displayText("Book the room for Friday at ten.") },
                "Space did not stop: \(host.names())")
        #expect(await session.coordinator.count("transcribe") == 1)
    }

    @Test("With every shortcut off, the Dictate stage is still named, still starts with Space, and still dictates")
    func dictateWithShortcutsOff() async throws {
        let session = try await WindowDictation.make()
        defer { Task { await session.close() } }
        session.controller.preferences.hotkeys.optionPressToTalkEnabled = false
        session.controller.preferences.hotkeys.handsFreeGlobalKeyCode = nil
        let host = host(session.controller)
        defer { host.close() }
        let stage = await host.settle { host.node { $0.name.contains("Dictate") } != nil }
        #expect(stage, "no Dictate stage: \(host.names())")
        let start = host.node(identifier: "today.start")
        #expect(start?.name == "Dictate", "the stage has no name or identifier: \(host.names())")
        #expect(start?.help.hasPrefix("Click to dictate here") == true, "the stage's hint is \(start?.help ?? "nothing")")

        host.moveKeyboardFocus(to: try #require(start))
        await host.settle()
        await host.keyPress(49, characters: " ")
        #expect(await host.settle { host.node(named: "Stop and copy") != nil }, "Space did not start: \(host.names())")
    }

    @Test("Esc discards a long recording, the note offers Undo, and Undo inserts it once")
    func discardThenUndo() async throws {
        let session = try await WindowDictation.make(outcome: .init(text: "Keep this one after all.", status: .inserted))
        defer { Task { await session.close() } }
        session.controller.undoDiscardMinimumRecording = 0
        let host = host(session.controller)
        defer { host.close() }
        await host.settle { host.node(identifier: "today.start") != nil }

        try await host.press("Dictate")
        #expect(await host.settle { host.node(named: "Discard") != nil })
        await host.keyPress(53, characters: "\u{1B}")
        #expect(await host.settle { says(host, "Discarded") }, "no Discarded note: \(host.names())")
        #expect(host.node(named: "Undo") != nil)
        #expect(cardText(host) == nil, "a discarded recording reached the page")

        try await host.press("Undo")
        #expect(await host.settle { cardText(host) == GroveFlowText.displayText("Keep this one after all.") }, "the card shows \(cardText(host) ?? "nothing")")
        #expect(!says(host, "Discarded"), "the Discarded note stayed after Undo")
        #expect(await session.coordinator.count("transcribe") == 1)
    }

    @Test("Cancel while transcribing returns to Dictate and adds nothing")
    func cancelWhileTranscribing() async throws {
        let older = F.entry(WindowSampleData.groceries, minutesAgo: 10)
        let session = try await WindowDictation.make(entries: [older])
        defer { Task { await session.close() } }
        await session.coordinator.hold()
        let host = host(session.controller)
        defer { host.close() }
        await host.settle { host.node(identifier: "today.start") != nil }

        try await host.press("Dictate")
        try await host.press("Stop and copy")
        #expect(await host.settle { says(host, "Transcribing") && host.node(named: "Cancel") != nil }, "\(host.names())")
        #expect(await eventually { await session.coordinator.count("transcribe") == 1 })
        try await host.press("Cancel")
        await session.coordinator.release()
        #expect(await host.settle { host.node(identifier: "today.start") != nil }, "Cancel left \(host.names())")
        #expect(await host.settle { cardText(host) == GroveFlowText.displayText(older.cleanText) },
                "the card shows \(cardText(host) ?? "nothing")")
    }

    @Test("Not inserted: the note keeps the words, Copy copies them and says so, and the note goes")
    func notInsertedCopy() async throws {
        let session = try await WindowDictation.make(outcome: .init(text: "Send the invoice today.", status: .failed))
        defer { Task { await session.close() } }
        let feedback = GroveFeedback()
        let host = host(session.controller, feedback: feedback)
        defer { host.close() }
        await host.settle { host.node(identifier: "today.start") != nil }

        try await host.press("Dictate")
        try await host.press("Stop and copy")
        #expect(await host.settle { says(host, "Not inserted") }, "no note: \(host.names())")
        try await host.press("Copy")
        var copied = ""
        for _ in 0..<12_000 where copied != "Send the invoice today." {
            copied = await session.clipboard.latestValue
            await host.pump(.milliseconds(10))
        }
        #expect(copied == "Send the invoice today.", "the clipboard has \(copied)")
        #expect(await host.settle { feedback.notice?.text == "Copied to the clipboard" })
        #expect(await host.settle { !says(host, "Not inserted") }, "the note stayed after Copy")
        #expect(await host.settle { cardText(host) == GroveFlowText.displayText("Send the invoice today.") })
    }

    @Test("Dismiss closes a Not inserted note and leaves the words on the page")
    func notInsertedDismiss() async throws {
        let session = try await WindowDictation.make(outcome: .init(text: "Call back at four.", status: .failed))
        defer { Task { await session.close() } }
        let host = host(session.controller)
        defer { host.close() }
        await host.settle { host.node(identifier: "today.start") != nil }
        try await host.press("Dictate")
        try await host.press("Stop and copy")
        #expect(await host.settle { says(host, "Not inserted") })
        try await host.press("Dismiss")
        #expect(await host.settle { host.node(identifier: "today.start") != nil && !says(host, "Not inserted") })
        #expect(cardText(host) == GroveFlowText.displayText("Call back at four."))
    }

    @Test("No speech: a quiet note that leaves on its own and adds nothing")
    func noSpeech() async throws {
        let session = try await WindowDictation.make(outcome: .init(text: "", status: .noSpeech))
        defer { Task { await session.close() } }
        let host = host(session.controller)
        defer { host.close() }
        await host.settle { host.node(identifier: "today.start") != nil }
        try await host.press("Dictate")
        try await host.press("Stop and copy")
        #expect(await host.settle { says(host, "No speech detected") }, "no note: \(host.names())")
        #expect(await host.settle { !says(host, "No speech detected") && host.node(identifier: "today.start") != nil },
                "the quiet note never left")
        #expect(cardText(host) == nil)
    }

    @Test("Microphone access off replaces Dictate with a way to turn it on, and turning it on brings Dictate back")
    func microphoneOffAndBack() async throws {
        let controller = F.sampleController()
        let host = host(controller)
        defer { host.close() }
        await host.settle { host.node(identifier: "today.start") != nil }

        controller.microphonePermissionStatus = .denied
        #expect(await host.settle { says(host, "Microphone access is off") }, "\(host.names())")
        #expect(host.node(named: "Open System Settings") != nil)
        #expect(host.node(identifier: "today.start") == nil, "Dictate stayed with the microphone off")

        controller.microphonePermissionStatus = .granted
        #expect(await host.settle { host.node(identifier: "today.start") != nil })
        #expect(!says(host, "Microphone access is off"))
    }

    @Test("A latest dictation from another day says which day, not only the time")
    func latestFromYesterdayNamesTheDay() async throws {
        let yesterday = F.entry(WindowSampleData.groceries, minutesAgo: 60 * 26)
        let controller = F.sampleController([yesterday])
        let host = host(controller)
        defer { host.close() }
        #expect(await host.settle { cardText(host) != nil })
        let card = try #require(host.node(named: "Latest dictation"))
        let lines = host.nodes(under: card).map(\.text)
        let expected = GroveEntryMeta.whenText(yesterday, showsDay: true)
        #expect(expected.contains(","), "the fixture is not from another day")
        #expect(lines.contains { $0.contains(expected) }, "the card reads \(lines.prefix(4)) for a dictation from \(expected)")
    }

    @Test("Earlier today lists at most twelve, while the heading counts every dictation of the day")
    func earlierTodayIsCapped() async throws {
        let entries = (0..<20).map { F.entry("Note number \($0) for the morning review.", minutesAgo: Double($0) / 60) }
        let controller = F.sampleController(entries)
        let flow = GroveTodayFlow()
        // Tall enough that the lazy list builds every row it shows.
        let host = TransitionHost(size: CGSize(width: 1120, height: 2_400), controller: controller) {
            GroveRenderHarness.window(.today, controller: controller) { GroveTodayView(flow: flow) }
        }
        defer { host.close() }
        await host.settle { cardText(host) != nil }
        func rows() -> [TransitionHost.Node] { host.nodes().filter { $0.role == "AXButton" && $0.name.hasPrefix("Note number ") } }
        // The lazy list builds its rows over several passes.
        #expect(await host.settle { rows().count >= 12 }, "\(rows().count) rows")
        #expect(rows().count == 12, "\(rows().count) rows")
        #expect(says(host, "20 dictations"), "\(host.names().prefix(10))")
        // The latest is the card and twelve are listed: the last row says how many are left out.
        let more = try #require(host.node { $0.role == "AXButton" && $0.name.hasSuffix("more in History") }, "\(host.names().suffix(6))")
        #expect(more.name == "7 more in History")
        #expect(more.help == "Opens the rest of today in History")
    }

    @Test("The hands-free key pressed in another app starts a dictation Today shows going there, and pressed again inserts it")
    func handsFreeKey() async throws {
        let session = try await WindowDictation.make(outcome: .init(text: "Agenda attached.", status: .inserted))
        defer { Task { await session.close() } }
        let host = host(session.controller)
        defer { host.close() }
        await host.settle { host.node(identifier: "today.start") != nil }

        session.hotkey.onToggleHandsFree?()
        #expect(await host.settle { host.node(named: "Stop and insert") != nil }, "the key did not start: \(host.names())")
        #expect(host.node(named: "Stop and copy") == nil, "a dictation from the key reads as one started here")
        session.hotkey.onToggleHandsFree?()
        #expect(await host.settle { says(host, "Inserted into") }, "no result: \(host.names())")
        #expect(await host.settle { cardText(host) == GroveFlowText.displayText("Agenda attached.") })
    }

    @Test("Holding Option shows Listening on Today, and letting go inserts")
    func holdOption() async throws {
        let session = try await WindowDictation.make(outcome: .init(text: "Quick note.", status: .inserted))
        defer { Task { await session.close() } }
        let host = host(session.controller)
        defer { host.close() }
        await host.settle { host.node(identifier: "today.start") != nil }

        session.hotkey.onPressToTalkStart?()
        #expect(await host.settle { says(host, "Listening") && host.node(named: "Discard") != nil }, "\(host.names())")
        #expect(session.controller.recordingLifecycleState == .recordingPressToTalk)
        session.hotkey.onPressToTalkStop?()
        #expect(await host.settle { cardText(host) == GroveFlowText.displayText("Quick note.") }, "\(host.names())")
    }

    @Test("Paste Last Dictation's shortcut inserts the newest dictation once and leaves Today as it was")
    func pasteLastShortcut() async throws {
        let latest = F.entry("Room 4B at three.")
        let session = try await WindowDictation.make(entries: [latest])
        defer { Task { await session.close() } }
        let host = host(session.controller)
        defer { host.close() }
        await host.settle { cardText(host) != nil }

        session.hotkey.onPasteLastShortcut?()
        var events: [String] = []
        for _ in 0..<12_000 where !events.contains("insert: Room 4B at three.") {
            events = await session.coordinator.events
            await host.pump(.milliseconds(10))
        }
        #expect(events.filter { $0.hasPrefix("insert: ") } == ["insert: Room 4B at three."], "events: \(events)")
        #expect(await host.settle { host.node(identifier: "today.start") != nil })
        #expect(cardText(host) == GroveFlowText.displayText(latest.cleanText))
        #expect(session.controller.recentEntries.count == 1, "pasting the last dictation saved another")
    }

    @Test("Fix a Word left armed on one dictation is not armed on the next dictation's card")
    func armedFixAWordDoesNotCarryOver() async throws {
        let older = F.entry("Room 4B at three.", minutesAgo: 10)
        let session = try await WindowDictation.make(entries: [older], outcome: .init(text: "Lunch moved to one.", status: .copiedOnly))
        defer { Task { await session.close() } }
        let host = host(session.controller)
        defer { host.close() }
        #expect(await host.settle { cardText(host) != nil }, "\(host.names())")

        try await host.press("Fix a Word")
        #expect(says(host, "Select a word in the text to fix it."), "\(host.names())")

        try await host.press("Dictate")
        #expect(await host.settle { host.node(named: "Stop and copy") != nil }, "not listening: \(host.names())")
        try await host.press("Stop and copy")
        #expect(await host.settle { cardText(host) == GroveFlowText.displayText("Lunch moved to one.") }, "the card shows \(cardText(host) ?? "nothing")")
        #expect(!says(host, "Select a word in the text to fix it."), "\(host.names())")
    }

    @Test("Copy under the latest dictation copies its words and says so")
    func copyLatest() async throws {
        let latest = F.entry(WindowSampleData.booking)
        let session = try await WindowDictation.make(entries: [latest])
        defer { Task { await session.close() } }
        let feedback = GroveFeedback()
        let host = host(session.controller, feedback: feedback)
        defer { host.close() }
        await host.settle { cardText(host) != nil }
        let copy = try #require(host.node(identifier: "today.copy"))
        #expect(copy.press())
        var copied = ""
        for _ in 0..<12_000 where copied != latest.cleanText {
            copied = await session.clipboard.latestValue
            await host.pump(.milliseconds(10))
        }
        #expect(copied == latest.cleanText)
        #expect(await host.settle { feedback.notice?.text == "Copied to the clipboard" })
    }
}
