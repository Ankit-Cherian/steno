import AppKit
import Foundation
import StenoKit
import Testing
@testable import Steno

@Suite("Grove menu panel")
@MainActor
struct GroveMenuTests {
    private func entries(_ count: Int) -> [TranscriptEntry] {
        (0..<count).map { index in
            TranscriptEntry(createdAt: Date(timeIntervalSince1970: 1_791_000_000 - Double(index) * 60),
                appBundleID: "com.example.app", rawText: "Dictation \(index)", cleanText: "Dictation \(index)",
                durationMS: 1_000, audioURL: nil, insertionStatus: .inserted)
        }
    }

    private func snapshot(entries count: Int = 4, paste: Bool = true) -> MenuBarSnapshot {
        MenuBarSnapshot(
            entries: entries(count),
            pasteShortcut: paste ? GlobalShortcut(keyCode: 9, modifiers: [.control, .option]) : nil,
            canPasteLast: true,
            devices: [InputDeviceOption(id: "a", name: "Built-in", isDefault: true), InputDeviceOption(id: "b", name: "USB", isDefault: false)]
        )
    }

    private func ids(_ rows: [GroveMenuRow]) -> [String] { rows.map(\.id) }

    // MARK: Layout

    @Test("The panel shows the model's rows in the reference order, in spaced groups")
    func layoutOrder() {
        let layout = GroveMenuLayout.make(snapshot: snapshot(), expanded: [])
        #expect(layout.primary?.action == .startDictation)
        #expect(layout.latest?.cleanText == "Dictation 0")
        // Copy Last Dictation is the glyph on the latest dictation's card, not a row of its own.
        #expect(layout.latestCopy?.id == "copy-last")
        #expect(layout.latestCopy?.action == .copyLatest)
        #expect(layout.groups.map(ids) == [
            ["paste-last", "earlier", "microphone"],
            ["open-steno", "settings", "quit"],
        ])
        #expect(ids(layout.navigable) == ["primary", "copy-last", "paste-last", "earlier", "microphone", "open-steno", "settings", "quit"])
    }

    @Test("An unsaved newest dictation is the card's dictation, and the saved one before it moves to Earlier")
    func unsavedNewestDictationIsTheCard() {
        var unsaved = snapshot(entries: 3)
        unsaved.hasUnsavedLast = true
        let layout = GroveMenuLayout.make(snapshot: unsaved, expanded: [.earlier])
        // Copy and Paste Last act on the unsaved dictation, so the card must not show the older one.
        #expect(layout.latest == nil)
        #expect(layout.latestCopy?.action == .copyLatest)
        let saved = unsaved.entries
        #expect(ids(layout.groups[0]).contains("earlier.\(saved[0].id.uuidString)"), "\(ids(layout.groups[0]))")
        #expect(ids(layout.groups[0]).contains("earlier.\(saved[1].id.uuidString)"))
        #expect(ids(layout.groups[0]).contains("earlier.\(saved[2].id.uuidString)"))
    }

    @Test("Stop, Discard and Undo Discard appear as the model offers them")
    func recordingRows() {
        var recording = snapshot()
        recording.lifecycle = .recordingHandsFree
        recording.isRecording = true
        let layout = GroveMenuLayout.make(snapshot: recording, expanded: [])
        #expect(layout.primary?.action == .stop)
        #expect(layout.groups.first.map(ids) == ["discard"])

        var undo = snapshot()
        undo.canUndoDiscard = true
        #expect(GroveMenuLayout.make(snapshot: undo, expanded: []).groups.first.map(ids) == ["undo-discard"])

        var transcribing = snapshot()
        transcribing.lifecycle = .transcribing
        #expect(GroveMenuLayout.make(snapshot: transcribing, expanded: []).primary == nil)
    }

    @Test("Paste Last Dictation shows its shortcut only when one is set")
    func pasteShortcutText() {
        let withShortcut = GroveMenuLayout.make(snapshot: snapshot(), expanded: [])
        #expect(withShortcut.row(withID: "paste-last")?.shortcut == "⌃⌥V")
        #expect(withShortcut.row(withID: "copy-last")?.shortcut == "⇧⌘C")
        let without = GroveMenuLayout.make(snapshot: snapshot(paste: false), expanded: [])
        #expect(without.row(withID: "paste-last")?.shortcut == nil)
        #expect(without.row(withID: "open-steno")?.shortcut == "⌘O")
        #expect(without.row(withID: "settings")?.shortcut == "⌘,")
        #expect(without.row(withID: "quit")?.shortcut == "⌘Q")
    }

    @Test("Shortcuts print as macOS prints them, function keys by name")
    func shortcutFormatting() throws {
        #expect(GroveMenuShortcut.text(key: "c", modifiers: [.command, .shift]) == "⇧⌘C")
        #expect(GroveMenuShortcut.text(key: "v", modifiers: [.control, .option]) == "⌃⌥V")
        #expect(GroveMenuShortcut.text(key: "", modifiers: .command) == nil)
        let f13 = String(Character(try #require(Unicode.Scalar(UInt32(NSF13FunctionKey)))))
        #expect(GroveMenuShortcut.text(key: f13, modifiers: []) == "F13")
    }

    @Test("Earlier and Microphone open in place and show the model's rows")
    func inlineSections() {
        let state = GroveMenuState(snapshot: snapshot())
        #expect(!state.layout.targets.contains { $0.isNested })
        state.toggle(.earlier)
        state.toggle(.microphone)
        let nested = state.layout.targets.filter(\.isNested)
        #expect(nested.filter { $0.id.hasPrefix("earlier.") }.count == 3)
        #expect(nested.filter { $0.id.hasPrefix("microphone.") }.map(\.title) == ["Follow the System Input", "Built-in", "USB"])
        #expect(nested.first { $0.id == "microphone.system" }?.isChecked == true)
        state.toggle(.earlier)
        #expect(!state.layout.targets.contains { $0.id.hasPrefix("earlier.") })
    }

    @Test("The Microphone row names the input in use: the chosen device, or the system's own")
    func microphoneDetail() {
        #expect(GroveMenuLayout.make(snapshot: snapshot(), expanded: []).row(withID: "microphone")?.detail == "Built-in")
        var chosen = snapshot()
        chosen.selectedDeviceID = "b"
        #expect(GroveMenuLayout.make(snapshot: chosen, expanded: []).row(withID: "microphone")?.detail == "USB")
        #expect(GroveMenuLayout.make(snapshot: MenuBarSnapshot(), expanded: []).row(withID: "microphone")?.detail == nil)
    }

    @Test("The header's second line says how to start, or where the words are going")
    func headerSubtitle() {
        #expect(GroveMenuState(snapshot: snapshot()).subtitle == "Hold ⌥ Option to dictate")
        var recording = snapshot()
        recording.lifecycle = .recordingHandsFree
        recording.isRecording = true
        #expect(GroveMenuState(snapshot: recording, targetAppName: "Mail").subtitle == "Into Mail")
        #expect(GroveMenuState(snapshot: recording).subtitle == "On this Mac")
        var transcribing = snapshot()
        transcribing.lifecycle = .transcribing
        #expect(GroveMenuState(snapshot: transcribing).subtitle == "On this Mac")
    }

    @Test("At rest the header names only a shortcut that is on, and says when the microphone is off")
    func headerTruthfulAtRest() {
        var handsFree = snapshot()
        handsFree.shortcuts = TodayShortcuts(optionHold: false, handsFreeKey: "F18")
        #expect(GroveMenuState(snapshot: handsFree).title == "Ready")
        #expect(GroveMenuState(snapshot: handsFree).subtitle == "Press F18 to dictate")
        #expect(GroveMenuState(snapshot: handsFree).statusHint == "press F18 to dictate")
        var off = snapshot()
        off.shortcuts = TodayShortcuts(optionHold: false, handsFreeKey: nil)
        #expect(GroveMenuState(snapshot: off).subtitle == "Shortcuts are off")
        var blocked = snapshot()
        blocked.shortcuts = TodayShortcuts(optionHold: false, handsFreeKey: nil, needsInputMonitoring: true)
        #expect(GroveMenuState(snapshot: blocked).subtitle == "Shortcuts need Input Monitoring")
        var both = snapshot()
        both.shortcuts = TodayShortcuts(optionHold: true, handsFreeKey: "F18")
        #expect(GroveMenuState(snapshot: both).subtitle == "Hold ⌥ Option to dictate")
        #expect(GroveMenuState(snapshot: both).statusHint == "hold Option to dictate")
        var denied = both
        denied.microphoneDenied = true
        #expect(GroveMenuState(snapshot: denied).title == "Not ready")
        // The strip under the header names the cause, so the header doesn't repeat it, and
        // VoiceOver hears it once, from the header.
        #expect(GroveMenuState(snapshot: denied).layout.attention != nil)
        #expect(GroveMenuState(snapshot: denied).subtitle == nil)
        #expect(GroveMenuState(snapshot: denied).statusHint == "microphone access is off")
    }

    @Test("Microphone choices are off while listening, and Earlier is hidden when there is nothing earlier")
    func sectionAvailability() {
        var recording = snapshot()
        recording.lifecycle = .recordingPressToTalk
        recording.isRecording = true
        let state = GroveMenuState(snapshot: recording)
        state.toggle(.microphone)
        #expect(state.layout.row(withID: "microphone.a")?.isEnabled == false)
        #expect(state.layout.row(withID: "microphone.system")?.isEnabled == true)
        let single = GroveMenuLayout.make(snapshot: snapshot(entries: 1), expanded: [])
        #expect(single.row(withID: "earlier") == nil)
    }

    // MARK: Keyboard

    @Test("Down and Up move through the enabled rows and wrap")
    func arrowNavigation() {
        let state = GroveMenuState(snapshot: snapshot())
        #expect(state.highlightedID == nil)
        state.handle(.down)
        #expect(state.highlightedID == "primary")
        state.handle(.down)
        #expect(state.highlightedID == "copy-last")
        state.handle(.up)
        state.handle(.up)
        #expect(state.highlightedID == "quit")
        state.handle(.down)
        #expect(state.highlightedID == "primary")
    }

    @Test("Up from nothing starts at the last row")
    func upFromNothing() {
        let state = GroveMenuState(snapshot: snapshot())
        state.handle(.up)
        #expect(state.highlightedID == "quit")
    }

    @Test("Disabled rows are skipped")
    func skipsDisabled() {
        // No dictations: Copy Last and Paste Last are off.
        let state = GroveMenuState(snapshot: MenuBarSnapshot())
        for _ in 0..<2 { state.handle(.down) }
        #expect(state.highlightedID == "microphone")
        #expect(state.layout.row(withID: "copy-last")?.isEnabled == false)
    }

    @Test("Return runs the highlighted row and closes the panel first")
    func returnRuns() {
        let state = GroveMenuState(snapshot: snapshot())
        var events: [String] = []
        state.close = { events.append("close") }
        state.perform = { events.append("run:\($0)") }
        state.handle(.down)
        state.handle(.down)
        state.handle(.activate)
        #expect(events == ["close", "run:copyLatest"])
    }

    @Test("Return on a section opens it and keeps the panel open; Right and Left open and close it")
    func disclosureKeys() {
        let state = GroveMenuState(snapshot: snapshot())
        var closed = false
        state.close = { closed = true }
        for _ in 0..<4 { state.handle(.down) }
        #expect(state.highlightedID == "earlier")
        state.handle(.activate)
        #expect(state.expanded == [.earlier])
        state.handle(.left)
        #expect(state.expanded.isEmpty)
        state.handle(.right)
        #expect(state.expanded == [.earlier])
        // Left from a nested row folds the section and returns to its title.
        state.handle(.down)
        #expect(state.highlightedID?.hasPrefix("earlier.") == true)
        state.handle(.left)
        #expect(state.expanded.isEmpty)
        #expect(state.highlightedID == "earlier")
        #expect(!closed)
    }

    @Test("Key equivalents run their rows and need exactly their modifiers")
    func keyEquivalents() {
        let state = GroveMenuState(snapshot: snapshot())
        var ran: [MenuBarAction] = []
        state.perform = { ran.append($0) }
        #expect(state.handle(.character("c", [.command, .shift])))
        #expect(state.handle(.character("O", [.command])))
        #expect(state.handle(.character(",", [.command])))
        #expect(state.handle(.character("v", [.control, .option])))
        #expect(state.handle(.character("q", [.command])))
        #expect(ran == [.copyLatest, .openSteno, .openSettings, .pasteLast, .quit])
        // ⌘C is not ⇧⌘C, and a bare letter is not a shortcut.
        #expect(!state.handle(.character("c", [.command])))
        #expect(!state.handle(.character("q", [])))
        #expect(!state.handle(.character("q", [.command, .option])))
        #expect(ran.count == 5)
    }

    @Test("A key equivalent for a row that is off does nothing")
    func disabledKeyEquivalent() {
        let state = GroveMenuState(snapshot: MenuBarSnapshot())
        var ran: [MenuBarAction] = []
        state.perform = { ran.append($0) }
        state.handle(.character("c", [.command, .shift]))
        #expect(ran.isEmpty)
    }

    // MARK: Pointer

    @Test("The pointer highlights the row under it and a click runs it")
    func pointer() {
        let state = GroveMenuState(snapshot: snapshot())
        state.frames = [
            "copy-last": CGRect(x: 262, y: 60, width: 20, height: 20),
            "quit": CGRect(x: 0, y: 300, width: 290, height: 24),
        ]
        var ran: [MenuBarAction] = []
        var closes = 0
        state.perform = { ran.append($0) }
        state.close = { closes += 1 }
        state.pointerMoved(to: CGPoint(x: 270, y: 70))
        #expect(state.highlightedID == "copy-last")
        state.click(at: CGPoint(x: 270, y: 70))
        state.click(at: CGPoint(x: 10, y: 310))
        state.click(at: CGPoint(x: 10, y: 200))
        #expect(ran == [.copyLatest, .quit])
        #expect(closes == 2)
        state.pointerMoved(to: CGPoint(x: 270, y: 70))
        state.pointerLeft()
        #expect(state.highlightedID == nil)
    }

    @Test("A moving pointer gives the highlight back from the keyboard, and the keyboard back from the pointer")
    func pointerAndKeyboardShareTheHighlight() {
        let state = GroveMenuState(snapshot: snapshot())
        state.frames = ["quit": CGRect(x: 0, y: 300, width: 290, height: 24)]
        state.handle(.down)
        #expect(state.usesKeyboard)
        state.pointerLeft()
        #expect(state.highlightedID == "primary")
        state.pointerMoved(to: CGPoint(x: 10, y: 310))
        #expect(!state.usesKeyboard)
        #expect(state.highlightedID == "quit")
    }

    // MARK: Placement

    @Test("The panel sits under the status item, moves in from a screen edge, and follows the item's screen")
    func placement() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let item = CGRect(x: 1300, y: 876, width: 28, height: 24)
        let size = CGSize(width: 290, height: 352)
        let frame = GroveMenuPlacement.frame(panelSize: size, statusItemFrame: item, screenFrame: screen)
        #expect(frame.maxX == 1440 - GroveMenuPlacement.edgeInset)
        #expect(frame.maxY == item.minY - GroveMenuPlacement.gap)
        let roomy = GroveMenuPlacement.frame(panelSize: size, statusItemFrame: CGRect(x: 600, y: 876, width: 28, height: 24), screenFrame: screen)
        #expect(roomy.minX == 600)

        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let leftItem = CGRect(x: -1918, y: 1056, width: 28, height: 24)
        let leftFrame = GroveMenuPlacement.frame(panelSize: size, statusItemFrame: leftItem, screenFrame: left)
        #expect(leftFrame.minX == left.minX + GroveMenuPlacement.edgeInset)
        #expect(GroveMenuPlacement.screenFrame(for: leftItem, among: [screen, left]) == left)
        #expect(GroveMenuPlacement.screenFrame(for: item, among: [screen, left]) == screen)
    }
}
