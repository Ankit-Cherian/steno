import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

@Suite("Grove Today rules")
@MainActor
struct GroveTodayRulesTests {
    private func entry(_ status: InsertionStatus, id: UUID = UUID(), pasted: Bool = false, reason: String? = nil,
                       text: String = "Move the planning meeting.") -> TranscriptEntry {
        TranscriptEntry(id: id, appBundleID: "com.apple.mail", rawText: text, cleanText: text, audioURL: nil,
                        insertionStatus: status, pasteAttempted: pasted ? true : nil,
                        record: reason.map { DictationRecord(copyReason: $0) })
    }

    @Test("Starting a dictation and the plate's own changes are instant; only leaving the stage moves")
    func phaseAnimations() {
        let outcome = GroveOutcome(kind: .inserted, title: "Inserted into Mail", text: "Move the planning meeting.")
        for reduceMotion in [false, true] {
            for phase in [GroveTodayPhase.listening, .transcribing, .settled(outcome)] {
                #expect(GroveTodayView.animation(arrivingAt: phase, reduceMotion: reduceMotion) == nil, "\(phase)")
            }
            #expect(GroveTodayView.animation(arrivingAt: .idle, reduceMotion: reduceMotion) != nil)
            #expect(GroveTodayView.animation(arrivingAt: .problem(GroveTodayFlow.noSpeech), reduceMotion: reduceMotion) != nil)
        }
    }

    @Test("The ready sentence puts its keys in keycaps and reads them aloud by name")
    func readyLine() {
        let both = GroveReadyLine.pieces(TodayShortcuts(optionHold: true, handsFreeKey: "F18"))
        #expect(both.contains(.key("⌥ Option")))
        #expect(both.contains(.key("F18")))
        #expect(GroveReadyLine.spoken(both) == "Ready. Hold Option in any app and speak. Press F18 for hands-free.")
        let off = GroveReadyLine.pieces(TodayShortcuts(optionHold: false, handsFreeKey: nil))
        #expect(!off.contains { if case .key = $0 { true } else { false } })
        #expect(GroveReadyLine.spoken(off).hasPrefix("Shortcuts are off."))
    }

    @Test("Without Input Monitoring no key is offered, and the line says what the shortcuts need")
    func readyLineWithoutInputMonitoring() {
        var hotkeys = AppPreferences.Hotkeys(optionPressToTalkEnabled: true)
        let blocked = TodayShortcuts(hotkeys, inputMonitoring: .denied)
        #expect(blocked == TodayShortcuts(optionHold: false, handsFreeKey: nil, needsInputMonitoring: true))
        #expect(GroveReadyLine.spoken(GroveReadyLine.pieces(blocked))
            == "Your shortcuts need Input Monitoring. Turn it on for Steno in System Settings › Privacy & Security.")
        #expect(TodayShortcuts(hotkeys, inputMonitoring: .granted).optionHold)
        hotkeys.optionPressToTalkEnabled = false
        hotkeys.handsFreeGlobalKeyCode = nil
        #expect(!TodayShortcuts(hotkeys, inputMonitoring: .denied).needsInputMonitoring)
    }

    @Test("Today's header counts Chinese words as words, English as before, once per change")
    func todayWords() {
        let entries = [
            entry(.inserted, text: "我们明天下午三点开会讨论新的设计方案。"),
            entry(.inserted, text: "我用 Steno 写了三封邮件。"),
            entry(.inserted, text: "Send the draft to Dana by Friday."),
        ]
        let memo = GroveTodayRowsMemo()
        let lists = memo.rows(entries, holding: false, baseline: nil)
        #expect(lists.today.count == 3)
        #expect(lists.todayWords == 10 + 8 + 7)
        #expect(entries.map(\.wordCount) == [10, 8, 7])
    }

    @Test("A result becomes the words the plate says")
    func resolve() {
        #expect(GroveTodayFlow.resolve(entry(.inserted), appName: "Mail")
                == .settled(GroveOutcome(kind: .inserted, title: "Inserted into Mail", text: "Move the planning meeting.")))
        #expect(GroveTodayFlow.resolve(entry(.copiedOnly, pasted: true), appName: "Terminal")
                == .settled(GroveOutcome(kind: .inserted, title: "Pasted into Terminal", text: "Move the planning meeting.")))
        #expect(GroveTodayFlow.resolve(entry(.copiedOnly, reason: "appChanged"), appName: "Mail")
                == .settled(GroveOutcome(kind: .copied, title: "Copied · App changed", text: "Move the planning meeting.")))
        guard case .problem(let problem) = GroveTodayFlow.resolve(entry(.failed), appName: "Mail") else {
            Issue.record("A failed insertion is a problem")
            return
        }
        #expect(problem.title == "Not inserted")
        #expect(problem.action == .copy)
        #expect(problem.actionTitle == "Copy")
    }

    @Test("Live words keep the last lines, cut on a word, with an ellipsis")
    func liveWordsTrim() {
        let short = GroveLiveWords.display(stable: "Move the meeting ", tail: "to Friday")
        #expect(short.stable == "Move the meeting " && short.tail == "to Friday")
        let stable = String(repeating: "alpha beta ", count: 40)
        let cut = GroveLiveWords.display(stable: stable, tail: "gamma", limit: 60)
        #expect(cut.stable.hasPrefix("…"))
        #expect(cut.tail == "gamma")
        #expect(cut.stable.count + cut.tail.count <= 62)
        let tailOnly = GroveLiveWords.display(stable: "ok ", tail: String(repeating: "word ", count: 80), limit: 40)
        #expect(tailOnly.stable.isEmpty && tailOnly.tail.hasPrefix("…"))
    }

    @Test("The status line says how a recording ended")
    func endHints() {
        #expect(GroveTodayFlow.EndHint.from(status: "Recording canceled.") == .canceled)
        #expect(GroveTodayFlow.EndHint.from(status: "Hands-free dictation canceled.") == .canceled)
        #expect(GroveTodayFlow.EndHint.from(status: "Recording discarded.") == .canceled)
        #expect(GroveTodayFlow.EndHint.from(status: "No speech detected.") == .noSpeech)
        #expect(GroveTodayFlow.EndHint.from(status: "Transcript inserted.") == .none)
    }
}

@Suite("Grove Today flow")
@MainActor
struct GroveTodayFlowTests {
    private let fast = GroveTodayFlow.Timing(resultWait: .milliseconds(80), settleHold: .milliseconds(60), quietNote: .milliseconds(60))
    private let oldID = UUID()

    private func result(_ status: InsertionStatus = .inserted) -> TranscriptEntry {
        TranscriptEntry(appBundleID: "com.apple.mail", rawText: "Hello there.", cleanText: "Hello there.", audioURL: nil, insertionStatus: status)
    }

    private func recording(_ flow: GroveTodayFlow) {
        flow.lifecycle(.recordingHandsFree, latestID: oldID, canUndoDiscard: false)
    }

    @Test("Listening holds new entries out of the list until the plate folds")
    func holds() {
        let flow = GroveTodayFlow(timing: fast)
        recording(flow)
        #expect(flow.phase == .listening)
        #expect(flow.isHoldingNewEntries)
        #expect(flow.baselineLatestID == oldID)
        flow.lifecycle(.transcribing, latestID: oldID, canUndoDiscard: false)
        #expect(flow.phase == .transcribing)
    }

    @Test("A result settles the plate, then folds it away and releases the new entry")
    func settlesAndFolds() async {
        let flow = GroveTodayFlow(timing: fast)
        recording(flow)
        flow.lifecycle(.transcribing, latestID: oldID, canUndoDiscard: false)
        flow.lifecycle(.idle, latestID: oldID, canUndoDiscard: false)
        #expect(flow.phase == .transcribing)
        flow.latestEntry(result(), appName: "Mail")
        guard case .settled(let outcome) = flow.phase else {
            Issue.record("The plate settles on a result: \(flow.phase)")
            return
        }
        #expect(outcome.title == "Inserted into Mail")
        #expect(flow.isHoldingNewEntries)
        #expect(await eventuallyOnMain { flow.phase == .idle })
        #expect(!flow.isHoldingNewEntries)
    }

    @Test("A result that reached History before the lifecycle ended is not lost")
    func earlyResult() {
        let flow = GroveTodayFlow(timing: fast)
        recording(flow)
        flow.lifecycle(.transcribing, latestID: oldID, canUndoDiscard: false)
        flow.latestEntry(result(), appName: "Mail")
        #expect(flow.phase == .transcribing)
        flow.lifecycle(.idle, latestID: nil, canUndoDiscard: false)
        if case .settled = flow.phase {} else { Issue.record("Expected settled, got \(flow.phase)") }
    }

    @Test("An earlier dictation's refresh during listening does not count as the result")
    func lateRefresh() {
        let flow = GroveTodayFlow(timing: fast)
        recording(flow)
        flow.latestEntry(result(), appName: "Mail")
        #expect(flow.phase == .listening)
        let late = flow.baselineLatestID
        #expect(late != oldID)
    }

    @Test("A failed insertion turns the plate into a note with its action")
    func problem() {
        let flow = GroveTodayFlow(timing: fast)
        recording(flow)
        flow.lifecycle(.idle, latestID: oldID, canUndoDiscard: false)
        flow.latestEntry(result(.failed), appName: "Mail")
        guard case .problem(let note) = flow.phase else {
            Issue.record("Expected a problem, got \(flow.phase)")
            return
        }
        #expect(note.action == .copy)
        #expect(!flow.isHoldingNewEntries)
        flow.noteActed()
        #expect(flow.phase == .idle)
    }

    @Test("A discard that can be undone becomes a note with Undo; one that cannot just ends")
    func discards() {
        let flow = GroveTodayFlow(timing: fast)
        recording(flow)
        flow.lifecycle(.idle, latestID: oldID, canUndoDiscard: true, hint: .canceled)
        guard case .problem(let note) = flow.phase else {
            Issue.record("Expected the discard note, got \(flow.phase)")
            return
        }
        #expect(note.action == .undoDiscard)
        flow.canUndoDiscardChanged(false)
        #expect(flow.phase == .idle)

        recording(flow)
        flow.lifecycle(.idle, latestID: oldID, canUndoDiscard: false, hint: .canceled)
        #expect(flow.phase == .idle)
    }

    @Test("Nothing recognised says so, and the note goes away by itself")
    func noSpeech() async {
        let flow = GroveTodayFlow(timing: fast)
        recording(flow)
        flow.lifecycle(.idle, latestID: oldID, canUndoDiscard: false, hint: .noSpeech)
        guard case .problem(let note) = flow.phase else {
            Issue.record("Expected a note, got \(flow.phase)")
            return
        }
        #expect(note.title == "No speech detected")
        #expect(note.isQuiet)
        #expect(await eventuallyOnMain { flow.phase == .idle })
    }

    @Test("A result that never arrives ends quietly, and a failed dictation leaves no note: the strip says it")
    func timeout() async {
        let quiet = GroveTodayFlow(timing: fast)
        recording(quiet)
        quiet.lifecycle(.idle, latestID: oldID, canUndoDiscard: false)
        #expect(quiet.phase == .transcribing)
        #expect(await eventuallyOnMain { quiet.phase == .idle })
    }

    @Test("A new recording replaces whatever the plate was doing")
    func restart() {
        let flow = GroveTodayFlow(timing: fast)
        recording(flow)
        flow.lifecycle(.idle, latestID: oldID, canUndoDiscard: false)
        flow.latestEntry(result(.failed), appName: "Mail")
        recording(flow)
        #expect(flow.phase == .listening)
    }
}
