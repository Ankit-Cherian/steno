import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Today on a live window: the latest card's Show all and Fix a Word, and the stage moving
/// through a whole dictation and folding its result into the card.
@Suite("Today transitions", .serialized)
@MainActor
struct TodayTransitionTests {
    typealias F = TransitionFixtures

    /// Today with a flow whose holds are short, so a result folds in without waiting.
    private func host(_ controller: DictationController, knobs: TransitionKnobs = TransitionKnobs()) -> TransitionHost {
        let flow = GroveTodayFlow(timing: .init(resultWait: .milliseconds(600), settleHold: .milliseconds(150),
                                                quietNote: .milliseconds(300)))
        return TransitionHost(controller: controller, knobs: knobs) {
            GroveRenderHarness.window(.today, controller: controller) { GroveTodayView(flow: flow) }
        }
    }

    private func cardText(_ host: TransitionHost) -> String? {
        host.transcriptViews().first?.textStorage?.string
    }

    @Test("The latest card's Show all draws every word, and Show fewer cuts it at 12 lines again")
    func latestCardShowAll() async throws {
        let controller = F.sampleController([F.entry(F.longText + " " + F.longText), F.entry(WindowSampleData.groceries, minutesAgo: 4)])
        let host = host(controller)
        defer { host.close() }
        await host.settle { host.transcriptViews().first != nil }
        let capped = DrawnText(try #require(host.transcriptViews().first))
        #expect(capped.lines == 12 && capped.isTruncated)

        try await host.press(prefix: "Show All ")
        #expect(await host.settle { host.transcriptViews().first.map { DrawnText($0).showsWholeText } ?? false },
                "Show all left words undrawn: \(host.transcriptViews().first.map { DrawnText($0) }.debugDescription)")
        #expect(host.node(named: "Show Fewer Words") != nil)

        try await host.press("Show Fewer Words")
        #expect(await host.settle { host.transcriptViews().first.map { DrawnText($0).lines == 12 && DrawnText($0).isTruncated } ?? false })
        #expect(host.node { $0.name.hasPrefix("Show All ") } != nil)
    }

    /// Selects `word` in the card's text, as a double click on it does.
    private func pick(_ word: String, in host: TransitionHost) async throws {
        let view = try #require(host.transcriptViews().first)
        // As a person would, wait until the text is ready to report a picked word.
        #expect(await host.settle { (view.delegate as? TranscriptTextView.Coordinator)?.picksWord == true },
                "the text never started listening for a word")
        let range = ((view.textStorage?.string ?? "") as NSString).range(of: word)
        try #require(range.location != NSNotFound)
        view.setSelectedRange(range)
        await host.settle()
    }

    /// The Fix a Word form's field, while the form is open.
    private func formField(_ host: TransitionHost) -> NSTextField? {
        host.views(NSTextField.self).first { $0.placeholderString == "Correct spelling" && $0.window != nil }
    }

    @Test("Fix a Word: the hint, the struck word and the form open and close, a fix redraws the words, and Undo puts them back")
    func fixAWord() async throws {
        let controller = F.sampleController()
        let host = host(controller)
        defer { host.close() }
        await host.settle { cardText(host) != nil }
        let hint = "Select a word in the text to fix it."
        #expect(host.node { $0.text == hint } == nil)

        try await host.press("Fix a Word")
        #expect(await host.settle { host.node { $0.text == hint } != nil }, "no hint: \(host.names())")
        try await pick("Friday", in: host)
        #expect(await host.settle { formField(host)?.stringValue == "Friday" }, "no form for Friday: \(host.names())")
        #expect(host.node { $0.text == hint } == nil, "the hint stayed with the form open")
        #expect(host.transcriptViews().first?.signature?.marks.strike != nil, "the word is not struck while it is fixed")

        await host.keyPress(53, characters: "\u{1B}")  // Esc is the form's Cancel
        #expect(await host.settle { formField(host) == nil }, "Cancel left the form open")
        #expect(host.transcriptViews().first?.signature?.marks.strike == nil, "the word stayed struck after Cancel")
        #expect(cardText(host)?.contains("Friday") == true)

        try await host.press("Fix a Word")
        try await pick("Friday", in: host)
        #expect(await host.settle { formField(host) != nil })
        try await host.type("Monday", into: "Correct spelling")
        await host.keyPress(36, characters: "\r")  // Return is the form's Fix
        #expect(await host.settle { cardText(host)?.contains("Monday") == true }, "the card still says \(cardText(host) ?? "")")
        #expect(await host.settle { host.node(named: "Copy Corrected Text") != nil })
        #expect(formField(host) == nil, "the form stayed after the fix")
        #expect(host.transcriptViews().first?.signature?.marks.fixed.isEmpty == false, "the fixed word is not marked")

        try await host.press("Undo")
        #expect(await host.settle { cardText(host)?.contains("Friday") == true && cardText(host)?.contains("Monday") == false })
        #expect(await host.settle { host.node(named: "Copy Corrected Text") == nil }, "the result note stayed after Undo")
        #expect(host.transcriptViews().first?.signature?.marks.fixed.isEmpty == true)
    }

    /// Replaces the correction in the open form, as Select All and typing do.
    private func setCorrection(_ text: String, in host: TransitionHost) async throws {
        let editor = try #require(host.popoverWindows.compactMap { $0.firstResponder as? NSTextView }.first, "the form's field is not being edited")
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        await host.settle()
    }

    @Test("Fix a Word's popover grows and shrinks with the correction without animating the resize")
    func fixAWordPopoverFollowsTheCorrection() async throws {
        let controller = F.sampleController()
        let host = host(controller)
        defer { host.close() }
        await host.settle { cardText(host) != nil }
        try await host.press("Fix a Word")
        try await pick("Friday", in: host)
        #expect(await host.settle { formField(host)?.stringValue == "Friday" }, "no form for Friday: \(host.names())")
        let popover = try #require(host.shownPopovers.last, "the form did not open in a popover")
        let window = try #require(formField(host)?.window)
        #expect(window !== host.window, "the form is drawn in the main window, not in its popover")
        // A popover resizes to its content during the window's layout. Animated, the resize runs a
        // nested run loop there, which crashes on macOS 26 when the update cycle commits from idle.
        #expect(!popover.animates, "the Fix a Word popover animates its resize")

        try await setCorrection("Fri", in: host)
        let short = window.frame.height
        try await setCorrection("Mondays, Tuesdays and Wednesdays before the quarterly planning review", in: host)
        let long = window.frame.height
        #expect(long > short, "the popover kept its height when the note under the field wrapped")
        for round in 0..<3 {
            try await setCorrection("Fri", in: host)
            #expect(await host.settle { window.frame.height == short }, "round \(round): the popover did not shrink back")
            try await setCorrection("Mondays, Tuesdays and Wednesdays before the quarterly planning review", in: host)
            #expect(await host.settle { window.frame.height == long }, "round \(round): the popover did not grow")
        }

        await host.keyPress(53, characters: "\u{1B}")
        #expect(await host.settle { formField(host) == nil }, "Esc left the popover open")
        #expect(cardText(host)?.contains("Friday") == true)
    }

    @Test("The stage goes ready, listening, transcribing, result, and folds into the card with the old latest in the list")
    func stageLifecycleFoldsIntoTheCard() async throws {
        let older = F.entry(WindowSampleData.latestText, minutesAgo: 20)
        let controller = F.sampleController([older, F.entry(WindowSampleData.groceries, minutesAgo: 40)])
        let host = host(controller)
        defer { host.close() }
        await host.settle { host.node(identifier: "today.start") != nil }
        #expect(cardText(host) == GroveFlowText.displayText(older.cleanText))

        controller.stageIsolatedPreviewLifecycle(.recordingHandsFree)
        controller.recordingStartedAt = Date()
        controller.stageIsolatedPreviewRecording(targetApp: "Mail", words: .init(stable: "Book the room", tail: " for Friday"))
        #expect(await host.settle { host.node(named: "Stop and insert") != nil }, "not listening: \(host.names())")
        #expect(host.node(identifier: "today.start") == nil, "the ready stage stayed up while listening")
        #expect(host.node { $0.text == "Listening" } != nil)
        #expect(host.node { $0.text.contains("Book the room for Friday") } != nil)
        #expect(host.node(named: "Latest dictation") == nil, "the card stayed while the stage is up")

        controller.stageIsolatedPreviewLifecycle(.transcribing)
        #expect(await host.settle { host.node(named: "Cancel") != nil })
        #expect(host.node(named: "Stop and insert") == nil, "Stop stayed while transcribing")
        #expect(host.node { $0.text.hasPrefix("Transcribing") } != nil)

        let result = F.entry("Book the room for Friday at ten.")
        controller.recentEntries.insert(result, at: 0)
        controller.stageIsolatedPreviewRecording(targetApp: nil, words: nil)
        controller.stageIsolatedPreviewLifecycle(.idle)
        controller.recordingStartedAt = nil
        #expect(await host.settle { host.node { $0.text.hasPrefix("Inserted into") } != nil }, "no result: \(host.names())")
        #expect(host.node(named: "Cancel") == nil)

        #expect(await host.settle { host.node(identifier: "today.start") != nil }, "the stage never came back to ready")
        #expect(await host.settle { cardText(host) == GroveFlowText.displayText(result.cleanText) },
                "the card shows \(cardText(host) ?? "nothing")")
        #expect(host.node { $0.text.hasPrefix("Inserted into") } == nil, "the result stayed after the fold")
        #expect(host.node(named: "Earlier today") != nil)
        #expect(host.nodes().contains { $0.role == "AXButton" && $0.name.hasPrefix(String(older.cleanText.prefix(30))) },
                "the old latest did not move into the list")
        #expect(host.transcriptViews().count == 1, "a second card is still drawn")
    }

    @Test("A new dictation's plate starts without the words of the one before")
    func nextDictationStartsWithoutOldWords() async throws {
        let controller = F.sampleController([F.entry(WindowSampleData.groceries, minutesAgo: 40)])
        let host = host(controller)
        defer { host.close() }
        await host.settle { host.node(identifier: "today.start") != nil }
        controller.stageIsolatedPreviewLifecycle(.recordingHandsFree)
        controller.recordingStartedAt = Date()
        controller.stageIsolatedPreviewRecording(targetApp: "Mail", words: .init(stable: "Book the room", tail: " for Friday"))
        #expect(await host.settle { host.node { $0.text.contains("Book the room for Friday") } != nil }, "no live words: \(host.names())")
        controller.stageIsolatedPreviewRecording(targetApp: "Mail", words: nil)
        controller.stageIsolatedPreviewLifecycle(.transcribing)
        #expect(await host.settle { host.node { $0.text.hasPrefix("Transcribing") } != nil })
        #expect(host.node { $0.text.contains("Book the room for Friday") } != nil, "the words left while transcribing")
        controller.recentEntries.insert(F.entry("The room is booked."), at: 0)
        controller.stageIsolatedPreviewLifecycle(.idle)
        controller.recordingStartedAt = nil
        #expect(await host.settle { host.node(identifier: "today.start") != nil }, "the stage never came back to ready")
        controller.stageIsolatedPreviewLifecycle(.recordingHandsFree)
        controller.recordingStartedAt = Date()
        #expect(await host.settle { host.node(named: "Stop and insert") != nil })
        await host.settle(timeout: .milliseconds(300)) { false }
        #expect(!host.nodes().contains { $0.text.contains("Book the room") },
                "the new dictation shows the last one's words")
        // Nothing was said this time: transcribing shows no words either.
        controller.stageIsolatedPreviewLifecycle(.transcribing)
        #expect(await host.settle { host.node { $0.text.hasPrefix("Transcribing") } != nil })
        #expect(!host.nodes().contains { $0.text.contains("Book the room") },
                "a silent dictation shows the last one's words while transcribing")
    }

    @Test("While listening the stage's quill follows the voice level")
    func stageQuillFollowsLevel() async throws {
        let controller = F.sampleController()
        let knobs = TransitionKnobs()
        knobs.reduceMotion = false
        let host = host(controller, knobs: knobs)
        defer { host.close() }
        controller.stageIsolatedPreviewLifecycle(.recordingHandsFree)
        controller.recordingStartedAt = Date()
        #expect(await host.settle { host.node(named: "Stop and insert") != nil })
        #expect(await host.settle { !host.quills().isEmpty }, "no quill on the stage")
        let before = Dictionary(uniqueKeysWithValues: host.quills().map { (ObjectIdentifier($0), TransitionHost.outerVane(of: $0)) })
        for level in [0.9, 0.2, 0.95, 0.4] as [Float] { controller.inputLevels.send(level) }
        let moved = await host.settle {
            host.quills().contains { quill in
                before[ObjectIdentifier(quill)].map { $0 != TransitionHost.outerVane(of: quill) } ?? false
            }
        }
        #expect(moved, "the quill's barbs do not follow the level")
    }
}
