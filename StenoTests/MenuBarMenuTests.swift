import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

@Suite("Menu bar menu")
@MainActor
struct MenuBarMenuTests {
    private func entries(_ count: Int) -> [TranscriptEntry] {
        (0..<count).map { index in
            TranscriptEntry(createdAt: Date(timeIntervalSince1970: 1_791_000_000 - Double(index) * 60),
                appBundleID: "com.example.app", rawText: "Dictation \(index)", cleanText: "Dictation \(index)",
                durationMS: 1_000, audioURL: nil, insertionStatus: .inserted)
        }
    }

    private func actions(_ items: [MenuBarItemSpec]) -> [MenuBarAction] {
        items.compactMap { if case .action(let action) = $0.kind { action } else { nil } }
    }

    @Test("With no dictations, Copy and Paste are off and no recent items show")
    func emptyMenu() {
        let items = MenuBarMenuModel.items(for: MenuBarSnapshot())
        let copy = items.first { $0.title == "Copy Last Dictation" }
        #expect(copy?.isEnabled == false)
        #expect(items.first { $0.title == "Paste Last Dictation" }?.isEnabled == false)
        #expect(!actions(items).contains(.stop))
        #expect(actions(items).filter { if case .copyEntry = $0 { true } else { false } }.isEmpty)
        #expect(items.last?.title == "Quit Steno")
        #expect(items.last?.keyEquivalent == "q")
    }

    @Test("The latest dictation is in the header; the next three are menu items that copy")
    func recentItems() {
        let entries = entries(5)
        let items = MenuBarMenuModel.items(for: MenuBarSnapshot(entries: Array(entries.prefix(4))))
        let recent = actions(items).compactMap { action -> UUID? in
            if case .copyEntry(let id) = action { id } else { nil }
        }
        #expect(recent == entries[1...3].map(\.id))
        #expect(items.first { $0.title == "Copy Last Dictation" }?.isEnabled == true)
    }

    @Test("While listening the menu offers Stop and Discard; otherwise it doesn't", arguments: [
        (RecordingLifecycleState.recordingPressToTalk, true),
        (.recordingHandsFree, true),
        (.transcribing, false),
        (.idle, false),
    ])
    func recordingControls(lifecycle: RecordingLifecycleState, offersStop: Bool) {
        let snapshot = MenuBarSnapshot(lifecycle: lifecycle, isRecording: offersStop)
        let menuActions = actions(MenuBarMenuModel.items(for: snapshot))
        #expect(menuActions.contains(.stop) == offersStop)
        #expect(menuActions.contains(.discard) == offersStop)
    }

    @Test("Undo Discard shows only while a discarded recording can be restored, and Copy Last reaches an unsaved dictation")
    func undoDiscardAndUnsaved() {
        let plain = actions(MenuBarMenuModel.items(for: MenuBarSnapshot()))
        #expect(!plain.contains(.undoDiscard))
        let undoable = actions(MenuBarMenuModel.items(for: MenuBarSnapshot(canUndoDiscard: true)))
        #expect(undoable.contains(.undoDiscard))
        let unsaved = MenuBarMenuModel.items(for: MenuBarSnapshot(canPasteLast: true, hasUnsavedLast: true))
        #expect(unsaved.first { $0.title == "Copy Last Dictation" }?.isEnabled == true)
        #expect(unsaved.first { $0.title == "Paste Last Dictation" }?.isEnabled == true)
    }

    @Test("The recent dictations start after the latest one, which is the unsaved one when History could not save it")
    func recentDictationsFollowTheLatest() {
        let saved = entries(5)
        let recentIDs = { (snapshot: MenuBarSnapshot) in
            MenuBarMenuModel.items(for: snapshot).compactMap { item -> UUID? in
                if case .action(.copyEntry(let id)) = item.kind { id } else { nil }
            }
        }
        #expect(recentIDs(MenuBarSnapshot(entries: saved)) == saved[1...3].map(\.id))
        #expect(recentIDs(MenuBarSnapshot(entries: saved, hasUnsavedLast: true)) == saved[0...2].map(\.id))
    }

    @Test("Paste Last Dictation shows its shortcut only when one is chosen")
    func pasteShortcut() {
        var snapshot = MenuBarSnapshot(entries: entries(1), canPasteLast: true)
        var paste = MenuBarMenuModel.items(for: snapshot).first { $0.title == "Paste Last Dictation" }
        #expect(paste?.keyEquivalent == "")
        #expect(paste?.isEnabled == true)
        snapshot.pasteShortcut = GlobalShortcut(keyCode: 9, modifiers: [.control, .option])
        paste = MenuBarMenuModel.items(for: snapshot).first { $0.title == "Paste Last Dictation" }
        #expect(paste?.keyEquivalent == "v")
        #expect(paste?.modifiers == [.control, .option])
    }

    @Test("A function key shortcut shows as a function key equivalent")
    func functionKeyShortcut() throws {
        let shortcut = try #require(GlobalShortcut(preferenceValue: "105"))
        let equivalent = try #require(shortcut.menuKeyEquivalent)
        #expect(equivalent.key == String(Character(Unicode.Scalar(UInt32(NSF13FunctionKey))!)))
        #expect(equivalent.modifiers.isEmpty)
    }

    @Test("The microphone submenu checks the chosen input")
    func microphoneSubmenu() {
        let devices = [InputDeviceOption(id: "a", name: "Built-in", isDefault: true), InputDeviceOption(id: "b", name: "USB", isDefault: false)]
        let items = MenuBarMenuModel.microphoneItems(for: MenuBarSnapshot(devices: devices, selectedDeviceID: "b"))
        #expect(items.filter(\.isChecked).map(\.title) == ["USB"])
        let following = MenuBarMenuModel.microphoneItems(for: MenuBarSnapshot(devices: devices))
        #expect(following.filter(\.isChecked).map(\.title) == ["Follow the System Input"])
    }

    @Test("Each command calls the matching controller path")
    func commands() {
        let target = RecordingTarget()
        target.recentEntries = entries(3)
        var other: [String] = []
        let runner = MenuBarCommandRunner(
            target: target,
            pasteLast: { other.append("paste") },
            selectMicrophone: { other.append("mic:\($0 ?? "system")") },
            openSteno: { other.append("open") },
            openSettings: { other.append("settings") },
            quit: { other.append("quit") }
        )
        runner.run(.stop)
        runner.run(.discard)
        runner.run(.startDictation)
        runner.run(.copyLatest)
        runner.run(.undoDiscard)
        runner.run(.copyEntry(target.recentEntries[2].id))
        runner.run(.turnOnMicrophone)
        target.microphonePermissionStatus = .denied
        runner.run(.turnOnMicrophone)
        runner.run(.pasteLast)
        runner.run(.selectMicrophone("usb"))
        runner.run(.selectMicrophone(nil))
        runner.run(.openSteno)
        runner.run(.openSettings)
        runner.run(.quit)
        #expect(target.calls == [
            "stopRecording", "cancelActiveRecording", "toggleHandsFree",
            "copyLastDictation", "undoDiscard", "copy:Dictation 2", "requestMicrophonePermission", "openMicrophoneSettings",
        ])
        #expect(other == ["paste", "mic:usb", "mic:system", "open", "settings", "quit"])
    }

    @Test("Every Grove panel row runs the same controller path as the native menu item it mirrors")
    func grovePanelRowsRunTheMatchingCommands() {
        let target = RecordingTarget()
        target.recentEntries = entries(4)
        var other: [String] = []
        var closes = 0
        let runner = MenuBarCommandRunner(
            target: target,
            pasteLast: { other.append("paste") },
            selectMicrophone: { other.append("mic:\($0 ?? "system")") },
            openSteno: { other.append("open") },
            openSettings: { other.append("settings") },
            quit: { other.append("quit") }
        )
        let devices = [InputDeviceOption(id: "usb", name: "USB", isDefault: false)]
        let snapshot = MenuBarSnapshot(
            lifecycle: .idle, entries: Array(target.recentEntries.prefix(4)), microphoneDenied: true,
            pasteShortcut: GlobalShortcut(keyCode: 9, modifiers: [.control, .option]), canPasteLast: true,
            canUndoDiscard: true, devices: devices
        )
        let state = GroveMenuState(snapshot: snapshot)
        state.perform = { runner.run($0) }
        state.close = { closes += 1 }
        state.toggle(.earlier)
        state.toggle(.microphone)
        // Every row that runs something, in panel order, except Dictate which is off with no microphone access.
        let rows = state.layout.targets.filter { $0.action != nil && $0.isEnabled }
        for row in rows { state.activate(row) }
        #expect(closes == rows.count)
        #expect(target.calls == [
            "requestMicrophonePermission",       // Turn On… (permission not yet asked)
            "copyLastDictation",                 // the copy glyph on the card
            "undoDiscard",
            "copy:Dictation 1", "copy:Dictation 2", "copy:Dictation 3",
        ])
        #expect(other == ["paste", "mic:system", "mic:usb", "open", "settings", "quit"])
    }

    @Test("Dictate starts hands-free and Stop stops, from the panel's header button")
    func grovePanelHeaderButton() {
        let target = RecordingTarget()
        let runner = MenuBarCommandRunner(target: target, pasteLast: {}, selectMicrophone: { _ in }, openSteno: {}, openSettings: {}, quit: {})
        let idle = GroveMenuState(snapshot: MenuBarSnapshot())
        idle.perform = { runner.run($0) }
        idle.activate(idle.layout.primary!)
        let recording = GroveMenuState(snapshot: MenuBarSnapshot(lifecycle: .recordingHandsFree, isRecording: true))
        recording.perform = { runner.run($0) }
        recording.activate(recording.layout.primary!)
        recording.activate(recording.layout.row(withID: "discard")!)
        #expect(target.calls == ["toggleHandsFree", "stopRecording", "cancelActiveRecording"])
    }

    @Test("The icon follows recording, transcribing and microphone access")
    func iconState() {
        #expect(MenuBarIconState.derive(lifecycle: .idle, isRecording: false, microphoneDenied: false) == .idle)
        #expect(MenuBarIconState.derive(lifecycle: .idle, isRecording: false, microphoneDenied: true) == .attention)
        #expect(MenuBarIconState.derive(lifecycle: .recordingHandsFree, isRecording: true, microphoneDenied: false) == .recording)
        #expect(MenuBarIconState.derive(lifecycle: .transcribing, isRecording: false, microphoneDenied: true) == .transcribing)
        #expect(MenuBarIconState.recording.accessibilityDescription == "Steno, recording")
        #expect(MenuBarIconState.transcribing.accessibilityDescription == "Steno, transcribing")
        #expect(MenuBarIconState.idle.accessibilityDescription == "Steno")
    }

    @Test("Levels map to four frames, written only on change, at most ten times a second, and never with Reduce Motion")
    func levelFrames() {
        #expect([Float(0), 0.2, 0.5, 0.9].map(MenuBarIcon.frame(for:)) == [0, 1, 2, 3])
        #expect(MenuBarIcon.recordingFrames.count == 4)
        var gate = MenuBarLevelGate()
        #expect(gate.update(level: 0.9, now: 0, reduceMotion: false) == 3)
        #expect(gate.update(level: 0.95, now: 0.5, reduceMotion: false) == nil)
        #expect(gate.update(level: 0.0, now: 0.05, reduceMotion: false) == nil)
        #expect(gate.update(level: 0.0, now: 0.11, reduceMotion: false) == 0)
        #expect(gate.update(level: 0.9, now: 1, reduceMotion: true) == nil)
    }

    @Test("Long dictations are shortened for the menu")
    func titles() {
        let entry = TranscriptEntry(createdAt: Date(), appBundleID: "x", rawText: "", cleanText: String(repeating: "word ", count: 20),
            durationMS: 1, audioURL: nil, insertionStatus: .inserted)
        let title = MenuBarMenuModel.title(for: entry)
        #expect(title.hasSuffix("…"))
        #expect(title.count <= 45)
    }
}

@MainActor
private final class RecordingTarget: MenuBarCommandTarget {
    var recentEntries: [TranscriptEntry] = []
    var microphonePermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    var calls: [String] = []
    func stopRecording() { calls.append("stopRecording") }
    func cancelActiveRecording() { calls.append("cancelActiveRecording") }
    func toggleHandsFree() { calls.append("toggleHandsFree") }
    func copyEntry(_ entry: TranscriptEntry) { calls.append("copy:\(entry.cleanText)") }
    func copyLastDictation() { calls.append("copyLastDictation") }
    func undoDiscard() { calls.append("undoDiscard") }
    func requestMicrophonePermission() { calls.append("requestMicrophonePermission") }
    func openMicrophoneSettings() { calls.append("openMicrophoneSettings") }
}

@Suite("Menu bar level")
@MainActor
struct MenuBarLevelTests {
    private final class Hotkey: HotkeyService {
        var onPressToTalkStart: (() -> Void)?
        var onPressToTalkStop: (() -> Void)?
        var onToggleHandsFree: (() -> Void)?
        var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
        var isOptionPressToTalkEnabled = true
        var globalToggleKeyCode: UInt16?
        func start() {}
        func stop() {}
    }

    @Test("The icon follows the controller's input level while recording, in frames, and not at all under Reduce Motion")
    func iconFollowsTheLevelStream() {
        let controller = makeTestDictationController(hotkey: Hotkey())
        defer { controller.teardown() }
        let menuBar = MenuBarController()
        menuBar.reducesMotion = { false }
        menuBar.iconState = .recording
        menuBar.observeInputLevel(of: controller)

        controller.inputLevels.send(0.9)
        #expect(menuBar.levelGate.frame == 3)

        let quiet = MenuBarController()
        quiet.reducesMotion = { true }
        quiet.iconState = .recording
        quiet.observeInputLevel(of: controller)
        controller.inputLevels.send(0.0)
        #expect(quiet.levelGate.frame == MenuBarIcon.staticRecordingFrame)
    }
}
