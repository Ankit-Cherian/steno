#if DEBUG
import AppKit
import StenoKit
import SwiftUI

/// `--perf-tour`, with `--isolated-ui-preview`: walks every screen and flow of the app with
/// 1,000 dictations plus the worst-case samples, driving the real windows the way a person or
/// VoiceOver does, and logs each step's name through `DictationLatency.tourStep` so the
/// main-thread watch attributes every busy stretch to a step. Finding controls is not counted.
///
/// `--perf-only <prefix>` runs only the steps whose names start with the prefix (plus the
/// sections the step needs). The tour quits the app when it is done. It never activates the app,
/// so it can run while someone works in another one. Debug builds only.
@MainActor
enum PerfTour {
    static var isRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--perf-tour") && IsolatedAppPreview.isRequested && !IsolatedAppPreview.isTestHost
    }

    private static var task: Task<Void, Never>?

    static func runIfRequested(controller: DictationController) {
        guard isRequested, task == nil else { return }
        task = Task { await Run(controller: controller).all() }
    }
}

// MARK: - The tour

@MainActor
private struct Run {
    let controller: DictationController
    let only: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.firstIndex(of: "--perf-only").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }()
    let ui = PerfTourDriver()

    /// `--perf-only` takes prefixes separated by commas.
    private func runs(_ step: String) -> Bool {
        guard let only else { return true }
        return only.split(separator: ",").contains { step.hasPrefix($0) || $0.hasPrefix(step) }
    }

    private func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    /// Starts a measured step, after checking that the tour never brought the app forward.
    private func step(_ name: String) {
        if NSApp.isActive { DictationLatency.note("tour: WARNING the app became active") }
        DictationLatency.tourStep(name)
    }

    func all() async {
        DictationLatency.busyThresholdMS = 16
        DictationLatency.watchMainThread()
        // Measured: with the tree on, recording and section switches cost the same instructions
        // as with it off (3.90 and 2.88 Ginstr against 3.83 and 2.88, three runs each).
        ui.enableAccessibility()
        guard await ui.wait(timeout: .seconds(20), until: { ui.mainWindow != nil && ui.segmented() != nil }) else {
            DictationLatency.note("tour: no main window")
            return quit()
        }
        ui.mainWindow?.orderFrontRegardless()
        controller.recentEntries = WindowSampleData.worstCaseEntries() + WindowSampleData.thousandEntries()
        await pause(1500)

        if let only, only.hasPrefix("flip-") {
            // Switches to one section and away fourteen times, so a sample isolates its cost.
            let section = String(only.dropFirst(5)), other = section == "Insights" ? "Today" : "Insights"
            for _ in 0..<14 {
                step("tour: flip to \(section)")
                ui.selectSegment(section)
                await pause(700)
                step("tour: flip away")
                ui.selectSegment(other)
                await pause(700)
            }
        }
        if runs("today") { await today() }
        if runs("controller change on Today") { await controllerChanges(on: "Today") }
        if runs("recording on Today") { await record(on: "Today", step: "tour: recording on Today") }
        if runs("sections") { await sections() }
        if runs("history") { await history() }
        if runs("controller change on History") { await controllerChanges(on: "History") }
        if runs("recording on History") { await record(on: "History", step: "tour: recording on History") }
        if runs("insights") { await insights() }
        if runs("controller change on Insights") { await controllerChanges(on: "Insights") }
        if runs("recording on Insights") { await record(on: "Insights", step: "tour: recording on Insights") }
        if runs("window") { await resizing() }
        if runs("settings") { await settings() }
        if runs("menu panel") { await menuPanel() }
        if runs("island") { await island() }
        if runs("onboarding") { await onboarding() }

        step("tour: done")
        await pause(500)
        quit()
    }

    /// Ends the preview at once: its storage is a temporary folder, and the normal quit waits
    /// on teardown work an isolated preview never finishes.
    private func quit() { exit(0) }

    /// Waits for `condition` and logs when it never held, so a step that did not happen is seen.
    private func expect(_ what: StaticString, timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
        if !(await ui.wait(timeout: timeout, until: condition)) { DictationLatency.note(what) }
    }

    /// Goes to a section as its own step, so the switch is never counted in the step before.
    private func show(_ section: String, for purpose: String) async {
        step("tour: go to \(section) for \(purpose)")
        ui.selectSegment(section)
        await pause(700)
    }

    // MARK: Today

    private func today() async {
        await show("Today", for: "today")
        step("tour: today idle")
        await pause(1500)

        step("tour: today show all")
        if await ui.press(prefix: "Show All ") {
            await expect("tour: TIMEOUT Show fewer") { ui.node(named: "Show Fewer Words") != nil }
            await pause(400)
            await ui.press("Show Fewer Words")
            await pause(400)
        } else { DictationLatency.note("tour: MISSING Show all") }

        step("tour: today fix a word")
        await fixAWord()
    }

    private func fixAWord() async {
        guard await ui.press("Fix a Word") else { return DictationLatency.note("tour: MISSING Fix a Word") }
        await expect("tour: TIMEOUT the word hint") { ui.node { $0.text == "Select a word in the text to fix it." } != nil }
        await pause(300)
        guard let view = ui.transcriptViews().first, let text = view.textStorage?.string else { return }
        let word = text.split(separator: " ").first { $0.count >= 7 && $0.allSatisfy(\.isLetter) }.map(String.init) ?? ""
        let range = (text as NSString).range(of: word)
        guard !word.isEmpty, range.location != NSNotFound else { return DictationLatency.note("tour: MISSING word") }
        view.setSelectedRange(range)
        guard await ui.wait(until: { ui.field("Correct spelling") != nil }) else { return DictationLatency.note("tour: MISSING fix form") }
        await pause(300)
        await ui.type("schedule", into: "Correct spelling")
        await ui.keyPress(36, characters: "\r", in: ui.field("Correct spelling")?.window)
        await expect("tour: TIMEOUT Undo") { ui.node(named: "Undo") != nil }
        await pause(400)
        await ui.press("Undo")
        await expect("tour: TIMEOUT Undo gone") { ui.node(named: "Undo") == nil }
        await pause(400)
    }

    // MARK: Controller changes

    /// Ten changes of the controller that show nothing new, such as a status set to the same
    /// text, each redrawing whatever observes it: what any change of app state costs here.
    private func controllerChanges(on section: String) async {
        await show(section, for: "controller change")
        step("tour: controller change on \(section)")
        for _ in 0..<10 {
            controller.status = controller.status
            await pause(250)
        }
    }

    // MARK: Recording

    private func record(on section: String, step name: String) async {
        await show(section, for: "recording")
        step(name)
        controller.stageIsolatedPreviewLifecycle(.recordingHandsFree)
        controller.recordingStartedAt = Date()
        controller.stageIsolatedPreviewRecording(targetApp: "Mail", words: nil)
        let sentence = WindowSampleData.longEmail.split(separator: " ").map(String.init)
        // Live words arrive the way the live transcription delivers them, and nothing else changes.
        let session = LiveTranscriptionSession(
            sessionID: UUID(), controllerGeneration: UUID(), runtimeGeneration: 1,
            runtimeIdentity: LiveTranscriptionRuntimeIdentity(
                protocolVersion: 0, runtimeIdentifier: "preview", modelIdentifier: "preview",
                vadIdentifier: nil, currentASRContextCount: 0, peakASRContextCount: 0))
        for tick in 0..<180 {
            controller.inputLevels.send(Float(0.2 + 0.6 * abs(sin(Double(tick) / 3))))
            if tick % 8 == 0 {
                let shown = sentence.prefix(tick / 8 * 3).joined(separator: " ")
                controller.publishLiveWords(LiveTranscriptionSnapshot(
                    session: session, stablePrefix: shown, revisableTail: " and then",
                    lastAcceptedRevision: UInt64(tick / 8 + 1), decodedAudioWatermark: UInt64(tick / 8 + 1) * 12_800))
            }
            await pause(33)
        }
        controller.stageIsolatedPreviewLifecycle(.transcribing)
        await pause(800)
        controller.stageIsolatedPreviewLifecycle(.idle)
        controller.recordingStartedAt = nil
        controller.stageIsolatedPreviewRecording(targetApp: nil, words: nil)
        await pause(1500)
    }

    // MARK: Sections

    private func sections() async {
        await show("Today", for: "sections")
        for (index, section) in ["History", "Insights", "Today", "History", "Insights", "Today"].enumerated() {
            step("tour: sections \(index < 3 ? "first" : "again") to \(section)")
            ui.selectSegment(section)
            await pause(700)
        }
    }

    // MARK: History

    private func history() async {
        await show("History", for: "history")
        if runs("history selection") {
            step("tour: history selection")
            for index in 0..<20 {
                ui.pressRow(at: index, in: "Dictations")
                await pause(250)
            }
        }
        if runs("history search") {
            step("tour: history search")
            await ui.type("planning meeting", into: "Search dictations", perCharacter: 90)
            await pause(400)
            await ui.clearField()
            await pause(600)
        }
        if runs("history filters") {
            step("tour: history filters")
            for filter in HistoryFilter.allCases where filter != .all {
                await ui.choose(menuItem: filter.menuTitle)
                await pause(500)
            }
            await ui.choose(menuItem: HistoryFilter.all.menuTitle)
            await pause(500)
        }
        // The worst-case latest dictation: the long email, cleaned up, with a full record.
        ui.pressRow(at: 0, in: "Dictations")
        await pause(500)
        if runs("history show all") {
            step("tour: history show all")
            if await ui.press(prefix: "Show All ") {
                await expect("tour: TIMEOUT Show Fewer Words") { ui.node(named: "Show Fewer Words") != nil }
                await pause(400)
                await ui.press("Show Fewer Words")
                await pause(400)
            } else { DictationLatency.note("tour: MISSING Show All") }
        }
        if runs("history how it was written") {
            step("tour: history how it was written")
            // ⌘I, the reader's shortcut for How It Was Written.
            await ui.keyPress(34, characters: "i", modifiers: .command)
            await pause(600)
        }
        if runs("history delete cancel") {
            step("tour: history delete cancel")
            if await ui.press("Delete") {
                await expect("tour: TIMEOUT the delete confirmation") { ui.node(named: HistoryRules.deleteOneTitle) != nil }
                await pause(300)
                await ui.press("Cancel")
                await expect("tour: TIMEOUT the confirmation gone") { ui.node(named: HistoryRules.deleteOneTitle) == nil }
                await pause(400)
            } else { DictationLatency.note("tour: MISSING Delete") }
        }
        if runs("history before cleanup") {
            // The first sample dictation with words cleanup removed.
            if let index = ui.rowIndex(containing: "Move the planning meeting", in: "Dictations") {
                ui.pressRow(at: index, in: "Dictations")
                await pause(500)
            }
            step("tour: history before cleanup")
            for _ in 0..<2 {
                if !(await ui.press("Before cleanup")) { DictationLatency.note("tour: MISSING Before cleanup") }
                await pause(500)
            }
        }
    }

    // MARK: Insights

    private func insights() async {
        await show("Insights", for: "insights")
        if runs("insights keys") {
            step("tour: insights keys")
            if let grid = ui.views(GroveDayGridView.self).first,
               let first = (grid.accessibilityChildren() ?? []).compactMap({ $0 as? GroveDayCellElement }).first {
                let frame = first.accessibilityFrameInParentSpace()
                await ui.click(grid, at: CGPoint(x: frame.midX, y: frame.midY))
                await pause(300)
                let days = (grid.accessibilityChildren() ?? []).count
                for _ in 0..<days {
                    await ui.key(125)
                    await pause(60)
                }
            } else { DictationLatency.note("tour: MISSING calendar") }
        }
        if runs("insights widths") {
            step("tour: insights widths")
            await ui.resizeMainWindow(steps: 8)
        }
    }

    // MARK: Window

    private func resizing() async {
        for section in ["Today", "History"] {
            let name = "tour: window resize \(section)"
            await show(section, for: "resizing")
            step(name)
            await ui.resizeMainWindow(steps: 10)
        }
    }

    // MARK: Settings

    private func settings() async {
        step("tour: settings open")
        SettingsRouter.shared.openWithoutActivating(.recording)
        guard await ui.wait(timeout: .seconds(5), until: { ui.settingsWindow != nil }) else {
            return DictationLatency.note("tour: MISSING Settings window")
        }
        ui.settingsWindow?.title = IsolatedAppPreview.settingsWindowTitle
        await pause(800)
        step("tour: settings panes")
        for section in SettingsSection.allCases.dropFirst() + [.recording] {
            if !(await ui.press(section.title, in: ui.settingsWindow)) { DictationLatency.note("tour: MISSING settings pane") }
            await pause(500)
        }
        step("tour: settings draft discard")
        if await ui.press("Show live transcript", in: ui.settingsWindow) {
            await pause(400)
            await ui.press("Microphone", in: ui.settingsWindow)
            await pause(400)
            await ui.press("Recording", in: ui.settingsWindow)
            await pause(400)
            await ui.press("Discard", in: ui.settingsWindow)
            await pause(500)
        } else { DictationLatency.note("tour: MISSING Show live transcript") }
        step("tour: settings close")
        ui.settingsWindow?.close()
        await pause(600)
    }

    // MARK: Menu bar panel

    private func menuPanel() async {
        let presenter = GroveMenuPresenter(installsMonitors: false, present: { $0.orderFrontRegardless() })
        defer { presenter.close() }
        let devices = [InputDeviceOption(id: "built-in", name: "MacBook Pro Microphone", isDefault: true),
                       InputDeviceOption(id: "usb", name: "Shure MV7+ Podcast Microphone (USB Audio Device)", isDefault: false)]
        let entries = Array(controller.recentEntries.prefix(20))
        func snapshot(_ lifecycle: RecordingLifecycleState = .idle, denied: Bool = false) -> MenuBarSnapshot {
            let recording = lifecycle == .recordingHandsFree || lifecycle == .recordingPressToTalk
            return MenuBarSnapshot(lifecycle: lifecycle, isRecording: recording,
                                   recordingStartedAt: recording ? Date() : nil, entries: entries, microphoneDenied: denied,
                                   canPasteLast: true, devices: devices, selectedDeviceID: "built-in")
        }
        let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let item = CGRect(x: screen.maxX - 220, y: screen.maxY - 24, width: 28, height: 24)

        step("tour: menu panel open")
        presenter.show(snapshot: snapshot(), targetAppName: "Mail", accent: controller.preferences.appearance.accent,
                       appearance: nil, statusItemFrame: item, screenFrame: screen, anchorWindow: nil, keyboardInitiated: false)
        await pause(800)
        step("tour: menu panel listening")
        presenter.refresh(snapshot: snapshot(.recordingHandsFree), targetAppName: "Mail")
        for tick in 0..<60 {
            presenter.state.haloSource.send(Float(0.2 + 0.6 * abs(sin(Double(tick) / 3))))
            await pause(33)
        }
        step("tour: menu panel transcribing and result")
        presenter.refresh(snapshot: snapshot(.transcribing), targetAppName: "Mail")
        await pause(600)
        presenter.refresh(snapshot: snapshot(), targetAppName: "Mail")
        await pause(600)
        step("tour: menu panel microphone")
        presenter.refresh(snapshot: snapshot(denied: true), targetAppName: "Mail")
        await pause(500)
        presenter.refresh(snapshot: snapshot(), targetAppName: "Mail")
        presenter.state.setExpanded(.microphone, true)
        await pause(500)
        presenter.state.setExpanded(.microphone, false)
        await pause(500)
        step("tour: menu panel close")
        presenter.close()
        await pause(600)
    }

    // MARK: Island

    private func island() async {
        let presenter = WaveformOverlayPresenter(observeAccessibilityChanges: false)
        presenter.appearance = .grove
        presenter.setStopAction {}
        presenter.setCancelAction {}
        presenter.updateAccentColor(NSColor(StenoDesign.theme(for: controller.preferences).accent))
        let session = LiveTranscriptionSession(
            sessionID: UUID(), controllerGeneration: UUID(), runtimeGeneration: 1,
            runtimeIdentity: LiveTranscriptionRuntimeIdentity(
                protocolVersion: 0, runtimeIdentifier: "preview", modelIdentifier: "preview",
                vadIdentifier: nil, currentASRContextCount: 0, peakASRContextCount: 0))
        let words = WindowSampleData.longEmail.split(separator: " ").map(String.init)
        presenter.setLiveTranscriptEnabled(true)
        step("tour: island ready")
        presenter.show(state: .listening(handsFree: true, elapsedSeconds: 0))
        await pause(600)
        if !NSApp.windows.contains(where: { $0 is NSPanel && $0.isVisible && $0.frame.width > 20 }) {
            DictationLatency.note("tour: MISSING island window")
        }
        step("tour: island listening")
        for tick in 0..<120 {
            presenter.updateInputLevel(Float(0.2 + 0.6 * abs(sin(Double(tick) / 3))))
            if tick % 8 == 0 {
                let shown = words.prefix(tick / 8 * 3)
                presenter.updateLiveTranscript(LiveTranscriptionSnapshot(
                    session: session, stablePrefix: shown.dropLast(min(3, shown.count)).joined(separator: " ") + " ",
                    revisableTail: shown.suffix(3).joined(separator: " "),
                    lastAcceptedRevision: UInt64(tick / 8 + 1), decodedAudioWatermark: UInt64(tick / 8 + 1) * 12_800))
            }
            await pause(33)
        }
        step("tour: island transcribing")
        presenter.show(state: .transcribing)
        await pause(800)
        step("tour: island result and dismissal")
        presenter.show(state: .result(.inserted(appName: "Mail", method: .typed), showsWords: true),
                       insertedWords: words.prefix(40).joined(separator: " "))
        presenter.finishResultPresentation()
        await pause(3500)
        presenter.hide()
        await pause(500)
    }

    // MARK: Onboarding

    private func onboarding() async {
        step("tour: onboarding show")
        controller.preferences.general.showOnboarding = true
        guard await ui.wait(timeout: .seconds(5), until: { ui.node { $0.name.hasPrefix("Continue to ") } != nil }) else {
            controller.preferences.general.showOnboarding = false
            return DictationLatency.note("tour: MISSING onboarding")
        }
        await pause(600)
        step("tour: onboarding steps")
        for _ in 0..<2 {
            await ui.press(prefix: "Continue to ")
            await pause(700)
        }
        for _ in 0..<2 {
            await ui.press("Back")
            await pause(700)
        }
        step("tour: onboarding close")
        controller.preferences.general.showOnboarding = false
        await pause(1000)
    }
}

// MARK: - Driving the windows

/// Finds the app's controls the way VoiceOver does and works them as a person would: buttons by
/// their accessible names, AppKit controls found in the view tree, typing through the field
/// editor, keys and mouse events sent to the views. Every lookup runs uncounted.
@MainActor
struct PerfTourDriver {
    /// SwiftUI builds its accessibility tree only once an assistive client asks for it.
    func enableAccessibility() {
        for name in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: name))
        }
    }

    var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix(SettingsRouter.mainWindowID) == true }
    }

    var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix(SettingsRouter.windowID) == true }
    }

    struct Node {
        let object: NSObject

        private func string(_ selector: Selector) -> String {
            guard object.responds(to: selector) else { return "" }
            let value = object.perform(selector)?.takeUnretainedValue()
            return (value as? String) ?? (value as? NSAttributedString)?.string ?? ""
        }

        private func flag(_ selector: Selector) -> Bool {
            guard object.responds(to: selector) else { return false }
            typealias Call = @convention(c) (NSObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Call.self)(object, selector)
        }

        var label: String { string(#selector(NSAccessibilityProtocol.accessibilityLabel)) }
        var title: String { string(#selector(NSAccessibilityProtocol.accessibilityTitle)) }
        var value: String { string(#selector(NSAccessibilityProtocol.accessibilityValue)) }
        var identifier: String { string(#selector(NSAccessibilityProtocol.accessibilityIdentifier)) }
        var role: String { string(#selector(NSAccessibilityProtocol.accessibilityRole)) }
        var name: String { label.isEmpty ? title : label }
        var text: String { value.isEmpty ? name : value }

        var children: [NSObject] {
            let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
            guard object.responds(to: selector) else { return [] }
            return (object.perform(selector)?.takeUnretainedValue() as? [Any])?.compactMap { $0 as? NSObject } ?? []
        }

        @discardableResult func press() -> Bool { flag(#selector(NSAccessibilityProtocol.accessibilityPerformPress)) }
    }

    private func roots(_ window: NSWindow?) -> [NSView] {
        guard let window = window ?? mainWindow else { return [] }
        let windows = [window] + (window.childWindows ?? []) + [window.attachedSheet].compactMap { $0 }
        return windows.filter(\.isVisible).compactMap { $0.contentView?.superview ?? $0.contentView }
    }

    func nodes(in window: NSWindow? = nil, under root: Node? = nil) -> [Node] {
        DictationLatency.uncounted {
            var result: [Node] = []
            var seen = Set<ObjectIdentifier>()
            func walk(_ object: NSObject, depth: Int) {
                guard depth < 80, seen.insert(ObjectIdentifier(object)).inserted else { return }
                let node = Node(object: object)
                if depth > 0 { result.append(node) }
                for child in node.children { walk(child, depth: depth + 1) }
            }
            if let root { walk(root.object, depth: 0) } else { roots(window).forEach { walk($0, depth: 0) } }
            return result
        }
    }

    func node(in window: NSWindow? = nil, where matches: (Node) -> Bool) -> Node? {
        let all = nodes(in: window)
        return DictationLatency.uncounted { all.first(where: matches) }
    }

    func node(named name: String, in window: NSWindow? = nil) -> Node? { node(in: window) { $0.name == name } }

    /// Presses the element named `name`. Returns whether there was one that took the press.
    @discardableResult
    func press(_ name: String, in window: NSWindow? = nil) async -> Bool {
        guard let found = node(named: name, in: window) else { return false }
        return found.press()
    }

    @discardableResult
    func press(prefix: String) async -> Bool {
        guard let found = node(where: { $0.name.hasPrefix(prefix) }) else { return false }
        return found.press()
    }

    private func rows(in group: String) -> [Node] {
        guard let list = node(where: { $0.name == group }) else { return [] }
        let all = nodes(under: list)
        return DictationLatency.uncounted { all.filter { $0.role == "AXButton" } }
    }

    func pressRow(at index: Int, in group: String) {
        let found = rows(in: group)
        if found.indices.contains(index) { found[index].press() }
    }

    func rowIndex(containing text: String, in group: String) -> Int? {
        rows(in: group).firstIndex { $0.name.contains(text) }
    }

    /// Every view of type `T` in the main window and its popovers, in tree order.
    func views<T: NSView>(_ type: T.Type, in window: NSWindow? = nil) -> [T] {
        DictationLatency.uncounted {
            var found: [T] = []
            func walk(_ view: NSView) {
                if let match = view as? T { found.append(match) }
                view.subviews.forEach(walk)
            }
            roots(window).forEach(walk)
            return found
        }
    }

    func transcriptViews() -> [TranscriptNSTextView] { views(TranscriptNSTextView.self) }

    func segmented() -> NSSegmentedControl? {
        views(NSSegmentedControl.self).first { control in
            (0..<control.segmentCount).contains { control.label(forSegment: $0) == "History" }
        }
    }

    /// Picks a section in the toolbar's section control, as a click on it does.
    func selectSegment(_ label: String) {
        guard let control = segmented(),
              let index = (0..<control.segmentCount).first(where: { control.label(forSegment: $0) == label }) else {
            return DictationLatency.note("tour: MISSING section control")
        }
        control.selectedSegment = index
        if let action = control.action { NSApp.sendAction(action, to: control.target, from: control) }
    }

    func field(_ name: String) -> NSTextField? {
        views(NSTextField.self).first { $0.isEditable && ($0.placeholderString == name || $0.accessibilityLabel() == name) }
    }

    /// Types `text` into the field named `name` through the field editor, a key at a time.
    func type(_ text: String, into name: String, perCharacter ms: Int = 30) async {
        // A SwiftUI field takes its accessible name once the accessibility tree has been read.
        await wait { _ = nodes(); return field(name) != nil }
        guard let target = field(name), let window = target.window else { return DictationLatency.note("tour: MISSING field") }
        window.makeFirstResponder(target)
        guard let editor = window.fieldEditor(false, for: target) as? NSTextView else { return }
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            try? await Task.sleep(for: .milliseconds(ms))
        }
    }

    /// Empties the field being edited, as Select All and Delete do.
    func clearField() async {
        guard let editor = mainWindow?.firstResponder as? NSTextView else { return }
        editor.selectAll(nil)
        editor.deleteBackward(nil)
    }

    /// Picks `title` from the pull-down menu that has it, as choosing the item with the mouse
    /// does, without running the menu's modal tracking.
    func choose(menuItem title: String) async {
        for button in views(NSPopUpButton.self) {
            guard let menu = button.menu else { continue }
            let willShow = NSSelectorFromString("popUpButtonCell:willShowMenu:")
            if let cell = button.cell, let delegate = cell.value(forKey: "delegate") as? NSObject, delegate.responds(to: willShow) {
                delegate.perform(willShow, with: cell, with: menu)
            }
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.delegate?.menuWillOpen?(menu)
            menu.update()
            let index = menu.indexOfItem(withTitle: title)
            guard index >= 0 else {
                menu.delegate?.menuDidClose?(menu)
                continue
            }
            menu.performActionForItem(at: index)
            menu.delegate?.menuDidClose?(menu)
            return
        }
        DictationLatency.note("tour: MISSING menu item")
    }

    /// A press of a key: key equivalents first (a default or cancel button), then the window.
    func keyPress(_ keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], in target: NSWindow? = nil) async {
        guard let window = target ?? mainWindow,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return }
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
    }

    /// A key sent to the main window's first responder.
    func key(_ keyCode: UInt16) async {
        guard let window = mainWindow,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: "",
                                           charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode) else { return }
        window.firstResponder?.keyDown(with: event)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                           pressure: type == .leftMouseUp ? 0 : 1)
    }

    /// A click at `point` in `view`'s coordinates.
    func click(_ view: NSView, at point: CGPoint) async {
        guard let window = view.window else { return }
        let inWindow = view.convert(point, to: nil)
        if let down = mouse(.leftMouseDown, at: inWindow, in: window) { view.mouseDown(with: down) }
        if let up = mouse(.leftMouseUp, at: inWindow, in: window) { view.mouseUp(with: up) }
    }

    /// Resizes the main window from its minimum to the screen's visible frame and back, as a drag
    /// of its corner does, then restores the frame it had.
    func resizeMainWindow(steps: Int) async {
        guard let window = mainWindow, let screen = window.screen ?? NSScreen.main else { return }
        let original = window.frame
        let visible = screen.visibleFrame
        let minimum = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize)).size
        let sizes = (0...steps).map { index -> CGSize in
            let t = CGFloat(index) / CGFloat(steps)
            return CGSize(width: minimum.width + (visible.width - minimum.width) * t,
                          height: max(minimum.height, 560) + (visible.height - max(minimum.height, 560)) * t)
        }
        for size in sizes + sizes.reversed() {
            window.setFrame(CGRect(x: visible.minX, y: visible.maxY - size.height, width: size.width, height: size.height),
                            display: true)
            try? await Task.sleep(for: .milliseconds(120))
        }
        window.setFrame(original, display: true)
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// Waits until `condition` holds, for at most `timeout`. Checks are not counted.
    @discardableResult
    func wait(timeout: Duration = .seconds(3), until condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }
}
#endif
