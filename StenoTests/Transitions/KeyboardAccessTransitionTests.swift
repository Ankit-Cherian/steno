import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// The window without a pointer: every control the keyboard reaches shows that it has the focus,
/// the dictation commands are in the menu bar, a list is one stop for Tab, Fix a Word works with
/// VoiceOver alone, small controls are big enough to hit, and Space starts the stage only from
/// the stage. The keyboard focus is moved as VoiceOver moves it, which gives SwiftUI controls
/// their focus and AppKit controls the first responder.
@Suite("Keyboard and VoiceOver access", .serialized)
@MainActor
struct KeyboardAccessTransitionTests {
    typealias F = TransitionFixtures

    static let controlRoles: Set<String> = ["AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXRadioButton",
                                            "AXTextField", "AXSlider", "AXLink", "AXComboBox", "AXSearchField"]

    private func today(_ controller: DictationController,
                       onOpenHistory: @escaping (UUID?, Bool) -> Void = { _, _ in }) -> TransitionHost {
        TransitionHost(controller: controller) {
            GroveRenderHarness.window(.today, controller: controller) { GroveTodayView(onOpenHistory: onOpenHistory) }
        }
    }

    private func history(_ controller: DictationController, selected: UUID? = nil, filter: HistoryFilter = .all) -> TransitionHost {
        TransitionHost(controller: controller) {
            GroveRenderHarness.window(.history, controller: controller) {
                SearchableGroveHistory(selected: selected, filter: filter)
            }
        }
    }

    // MARK: Focus rings

    enum Screen: String, CaseIterable, CustomTestStringConvertible {
        case today, history, historySearched, historyFiltered, insights
        var testDescription: String { rawValue }
    }

    /// The controls the keyboard can reach, inside the window and drawn.
    private func reachable(_ host: TransitionHost) -> [TransitionHost.Node] {
        let window = host.window.frame
        return host.nodes().filter { node in
            Self.controlRoles.contains(node.role) && node.isFocusTarget
                && node.screenFrame.width > 1 && window.contains(node.screenFrame.insetBy(dx: 1, dy: 1))
        }
    }

    @Test("Every control the keyboard reaches on Today, History and Insights draws a ring when it has the focus",
          arguments: Screen.allCases)
    func everyReachableControlShowsFocus(screen: Screen) async throws {
        let long = F.entry(F.longText + " " + F.longText)
        let copied = F.entry(WindowSampleData.booking, minutesAgo: 6, status: .copiedOnly)
        let controller = F.sampleController([long, F.entry(WindowSampleData.groceries, minutesAgo: 3), copied])
        let host: TransitionHost
        switch screen {
        case .today: host = today(controller)
        case .history, .historySearched: host = history(controller, selected: long.id)
        case .historyFiltered: host = history(controller, filter: .copied)
        case .insights:
            host = TransitionHost(controller: controller) {
                GroveRenderHarness.window(.insights, controller: controller) { GroveInsightsView() }
            }
        }
        defer { host.close() }
        await host.settle { host.node(named: "Dictate") != nil || host.node(named: "Search dictations") != nil || screen == .insights }
        if screen == .historySearched {
            try await host.type("agenda", into: "Search dictations")
            #expect(await host.settle { host.node(named: "Clear search") != nil }, "no Clear search: \(host.names())")
        }
        await host.pump(.milliseconds(60))

        let controls = reachable(host)
        // Insights has no buttons: its calendar is one stop that the arrow keys move in.
        if screen != .insights { #expect(!controls.isEmpty, "\(screen): nothing the keyboard reaches") }
        var unringed: [String] = []
        for node in controls {
            let change = await host.focusRingChange(node)
            if change < 0.02 { unringed.append("\(node.role) “\(node.name)” (\(String(format: "%.3f", change)))") }
        }
        #expect(unringed.isEmpty, "\(screen): no visible focus on \(unringed)")
    }

    // MARK: Menu bar

    /// Every item of the main menu, by the menu it is in.
    private func menuItems() -> [(menu: String, title: String, key: String, modifiers: NSEvent.ModifierFlags)] {
        (NSApp.mainMenu?.items ?? []).flatMap { top in
            (top.submenu?.items ?? []).map { (top.title, $0.title, $0.keyEquivalent, $0.keyEquivalentModifierMask) }
        }
    }

    @Test("Search History, Fix a Word and How It Was Written are in the menu bar with ⌘F, ⌘E and ⌘I")
    func commandsAreInTheMenuBar() {
        let items = menuItems()
        for (menu, title, key) in [("Edit", "Search History", "f"), ("Dictation", "Fix a Word…", "e"),
                                   ("Dictation", "How It Was Written", "i")] {
            let item = items.first { $0.menu == menu && $0.title == title }
            #expect(item != nil, "no “\(title)” in the \(menu) menu: \(items.map { "\($0.menu) › \($0.title)" })")
            #expect(item?.key == key && item?.modifiers == .command, "“\(title)” is on \(item?.key ?? "nothing"), not ⌘\(key.uppercased())")
        }
    }

    @Test("On Today, ⌘E starts Fix a Word on the latest card and ⌘I opens How it was written")
    func todayCommandKeys() async throws {
        var opened: [(UUID?, Bool)] = []
        let entry = F.entry(WindowSampleData.latestText)
        let host = today(F.sampleController([entry]), onOpenHistory: { opened.append(($0, $1)) })
        defer { host.close() }
        await host.settle { host.transcriptViews().first != nil }
        host.window.makeKey()
        await host.keyPress(14, characters: "e", modifiers: .command)
        #expect(await host.settle { host.node { $0.text == "Select a word in the text to fix it." } != nil }, "⌘E did not start Fix a Word")
        await host.keyPress(34, characters: "i", modifiers: .command)
        #expect(opened.count == 1 && opened.first?.0 == entry.id && opened.first?.1 == true, "⌘I opened \(opened)")
    }

    @Test("On Today, ⌘E and ⌘I act on a dictation that arrived after the page first drew")
    func todayCommandKeysFollowANewDictation() async throws {
        var opened: [(UUID?, Bool)] = []
        let older = F.entry("Move the meeting to Friday afternoon.", minutesAgo: 5)
        let controller = F.sampleController([older])
        let host = today(controller, onOpenHistory: { opened.append(($0, $1)) })
        defer { host.close() }
        await host.settle { host.transcriptViews().first?.textStorage?.string.contains("Friday") == true }
        let newer = F.entry("Please send the report before lunch.")
        controller.recentEntries.insert(newer, at: 0)
        #expect(await host.settle { host.transcriptViews().first?.textStorage?.string.contains("Please send") == true },
                "the new dictation never reached the card")
        host.window.makeKey()
        await host.keyPress(14, characters: "e", modifiers: .command)
        #expect(await host.settle { host.node { $0.text == "Select a word in the text to fix it." } != nil }, "⌘E did not start Fix a Word")
        #expect(host.transcriptViews().first?.textStorage?.string.contains("Please send") == true)
        await host.keyPress(34, characters: "i", modifiers: .command)
        #expect(opened.count == 1 && opened.first?.0 == newer.id && opened.first?.1 == true,
                "⌘I opened \(opened.map { $0.0 == older.id ? "the older dictation" : String(describing: $0.0) })")
    }

    // MARK: A list is one stop

    /// The places SwiftUI's keyboard focus can stop in the window: one key-view proxy each.
    private func focusStops(_ host: TransitionHost) -> Int {
        host.views(NSView.self).filter { NSStringFromClass(type(of: $0)).contains("KeyViewProxy") }.count
    }

    @Test("History's list is one stop for Tab however many rows it shows, and its search and options are stops")
    func historyListIsOneStop() async throws {
        func stops(rows: Int) async -> Int {
            // 45 minutes apart, so Around then in the reader stays empty and adds no buttons.
            let entries = (0..<rows).map { F.entry("Dictation number \($0) about the plan.", minutesAgo: Double($0) * 45) }
            let host = history(F.sampleController(entries), selected: entries[0].id)
            defer { host.close() }
            await host.settle { host.nodes().filter { $0.identifier.hasPrefix("history.row.") }.count == rows }
            await host.pump(.milliseconds(60))
            #expect(host.node(identifier: "history.more")?.isFocusTarget == true, "History options is not reachable")
            #expect(host.node(named: "Search dictations")?.isFocusTarget == true, "the search is not reachable")
            return focusStops(host)
        }
        let few = await stops(rows: 2)
        let more = await stops(rows: 8)
        #expect(few > 0, "no focus stops at all")
        #expect(more == few, "six more rows added \(more - few) Tab stops")
    }

    // MARK: Fix a Word with VoiceOver

    /// The card's words, as VoiceOver reads them: the element that carries the dictation's actions.
    private func entryElement(_ host: TransitionHost) -> TransitionHost.Node? {
        host.node { $0.customActionNames.contains { $0.hasPrefix("Fix a Word") } }
    }

    /// The form's only pop-up button, in the popover's window rather than the host's.
    static func isWordMenu(_ button: NSPopUpButton) -> Bool {
        button.window != nil && !(button.window is TransitionWindow)
    }

    private func wordMenu(_ host: TransitionHost) -> NSPopUpButton? {
        host.views(NSPopUpButton.self).first(where: Self.isWordMenu)
    }

    private func formField(_ host: TransitionHost) -> NSTextField? {
        host.views(NSTextField.self).first { $0.placeholderString == "Correct spelling" && $0.window != nil }
    }

    @Test("VoiceOver's Fix a Word action opens the form with every word to choose from, and fixes the one chosen")
    func fixAWordWithVoiceOver() async throws {
        let host = today(F.sampleController())
        defer { host.close() }
        await host.settle { entryElement(host) != nil }
        let element = try #require(entryElement(host), "no element with the dictation's actions")
        #expect(element.perform(action: "Fix a Word…"), "no Fix a Word… action: \(element.customActionNames)")
        #expect(await host.settle { wordMenu(host) != nil }, "no list of words: \(host.names())")
        let opened = try #require(wordMenu(host)?.window?.frame)
        try await host.choose(menuItem: "Friday", in: Self.isWordMenu)
        #expect(await host.settle { formField(host)?.stringValue == "Friday" }, "the field says \(formField(host)?.stringValue ?? "nothing")")
        let chosen = try #require(wordMenu(host)?.window?.frame)
        #expect(abs(chosen.minX - opened.minX) < 1 && abs(chosen.maxY - opened.maxY) < 1,
                "the form moved from \(opened) to \(chosen) when another word was chosen")

        let editor = try #require(host.popoverWindows.compactMap { $0.firstResponder as? NSTextView }.first, "the field is not being edited")
        editor.selectAll(nil)
        editor.insertText("Monday", replacementRange: editor.selectedRange())
        await host.settle()
        await host.keyPress(36, characters: "\r")
        #expect(await host.settle { host.transcriptViews().first?.textStorage?.string.contains("Monday") == true },
                "the card still says \(host.transcriptViews().first?.textStorage?.string ?? "")")
    }

    @Test("Without a pointer, Fix a Word offers the same list next to its hint")
    func fixAWordFromTheKeyboard() async throws {
        let host = today(F.sampleController())
        defer { host.close() }
        await host.settle { host.node(named: "Fix a Word") != nil }
        try await host.press("Fix a Word")
        #expect(await host.settle { host.node(named: "Choose from a List…") != nil }, "no list next to the hint: \(host.names())")
        try await host.press("Choose from a List…")
        #expect(await host.settle { wordMenu(host) != nil }, "the list did not open the form")
    }

    // MARK: Fix a Word: where the keyboard goes

    /// Every way into Fix a Word's form from History. The two "while searching" ways start with
    /// the search field holding the keyboard, as it does once a window becomes key.
    enum FixWayIn: String, CaseIterable, CustomTestStringConvertible {
        case clickedWord, spaceOnChooseFromList, voiceOverPress, voiceOverPressWhileSearching, clickedWordWhileSearching
        var testDescription: String { rawValue }
        var startsInSearch: Bool { self == .voiceOverPressWhileSearching || self == .clickedWordWhileSearching }
    }

    /// Whether keys go to Correct spelling: the popover leaves the host window key and shares
    /// its first responder, so the host window's first responder is the field's editor.
    private func keyboardIsInForm(_ host: TransitionHost) -> Bool {
        guard let editor = host.window.firstResponder as? NSTextView, let field = formField(host) else { return false }
        return (editor.delegate as AnyObject?) === field
    }

    /// Characters typed on the keyboard, sent where AppKit sends them: to the key window.
    private func typeOnKeyboard(_ host: TransitionHost, _ text: String) async {
        for character in text {
            let key: NSWindow = NSApp.keyWindow ?? host.window
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: key.windowNumber, context: nil, characters: String(character),
                                               charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0)
            else { continue }
            if !key.performKeyEquivalent(with: event) { key.sendEvent(event) }
            await host.pump(.milliseconds(2))
        }
        await host.settle()
    }

    @Test("Fix a Word's form takes the keyboard by every way in from History, and typing then Return fixes the word",
          arguments: FixWayIn.allCases)
    func fixFormTakesTheKeyboard(_ way: FixWayIn) async throws {
        let first = F.entry("Send the plan to the team today.")
        let session = try await WindowDictation.make(entries: [first, F.entry("Please send the report to Kubernetes before lunch.", minutesAgo: 2)])
        defer { Task { await session.close() } }
        let feedback = GroveFeedback()
        feedback.announce = { _ in }
        let controller = session.controller
        let host = TransitionHost(controller: controller) {
            GroveRenderHarness.window(.history, controller: controller, feedback: feedback) {
                GroveHistoryView(initialSelectedEntryID: first.id)
            }
        }
        defer { host.close() }
        let reader = { host.transcriptViews().first?.textStorage?.string }
        await host.settle { reader() != nil }
        if way.startsInSearch { try await host.type("", into: "Search dictations") }
        host.window.makeKey()
        await host.keyPress(14, characters: "e", modifiers: .command)
        #expect(await host.settle { host.node(named: "Choose from a List…") != nil }, "⌘E did not show the hint: \(host.names())")

        switch way {
        case .clickedWord, .clickedWordWhileSearching:
            let view = try #require(host.transcriptViews().first)
            view.setSelectedRange(((view.textStorage?.string ?? "") as NSString).range(of: "Send"))
        case .spaceOnChooseFromList:
            host.moveKeyboardFocus(to: try #require(host.node(named: "Choose from a List…")))
            await host.settle()
            await host.keyPress(49, characters: " ")
        case .voiceOverPress, .voiceOverPressWhileSearching:
            #expect(try #require(host.node(named: "Choose from a List…")).press())
        }
        #expect(await host.settle { formField(host) != nil }, "the form did not open")
        #expect(await host.settle { keyboardIsInForm(host) }, "the keyboard is not in Correct spelling")

        await typeOnKeyboard(host, "Deliver")
        await host.keyPress(36, characters: "\r")
        #expect(await host.settle(timeout: .seconds(2)) { reader()?.contains("Deliver") == true },
                "typing and Return did not fix the word: \(reader() ?? "nothing")")
    }

    // MARK: Targets

    @Test("Clear search is at least 20 points each way")
    func smallControlsAreBigEnoughToHit() async throws {
        let entry = F.entry("Please move the closing date in section four to September 25 before it goes out.")
        let history = history(F.sampleController([entry]), selected: entry.id)
        defer { history.close() }
        await history.settle { history.node(named: "Search dictations") != nil }
        try await history.type("closing", into: "Search dictations")
        #expect(await history.settle { history.node(named: "Clear search") != nil }, "no Clear search: \(history.names())")
        let clear = try #require(history.node(named: "Clear search")).screenFrame
        #expect(clear.width >= 20 && clear.height >= 20, "Clear search is \(clear.size)")
    }

    @Test("History's options take a click across at least 24 points each way, from the magnifier and from the filter's name")
    func historyOptionsAreBigEnoughToHit() async throws {
        let entry = F.entry(WindowSampleData.booking, status: .copiedOnly)
        let host = history(F.sampleController([entry]), selected: entry.id, filter: .copied)
        defer { host.close() }
        #expect(await host.settle { host.node(identifier: "history.filter") != nil }, "no filter name: \(host.names())")
        for identifier in ["history.more", "history.filter"] {
            let node = try #require(host.node(identifier: identifier), "no \(identifier)")
            let center = CGPoint(x: node.screenFrame.midX, y: node.screenFrame.midY)
            let target = host.views(NSPopUpButton.self).compactMap { button -> CGRect? in
                guard let window = button.window else { return nil }
                return window.convertToScreen(button.convert(button.bounds, to: nil))
            }.first { $0.contains(center) }
            let size = try #require(target, "no pop-up button under \(identifier)").size
            #expect(size.width >= 24 && size.height >= 24, "\(identifier) takes clicks across \(size)")
        }
    }

    @Test("A click in the gap between two days of the calendar picks a day at the window's minimum width")
    func calendarGapPicksADay() async throws {
        let controller = F.sampleController()
        let host = TransitionHost(size: CGSize(width: MainWindowMetrics.minWidth, height: MainWindowMetrics.minHeight),
                                  controller: controller) {
            GroveRenderHarness.window(.insights, controller: controller) { GroveInsightsView() }
        }
        defer { host.close() }
        let prompt = "Choose a day to see how much you dictated."
        #expect(await host.settle { !host.views(GroveDayGridView.self).isEmpty && host.node { $0.text == prompt } != nil })
        let grid = try #require(host.views(GroveDayGridView.self).first)
        // Seven rows of squares with six gaps between them; the grid's top-left is the first day.
        let gapWidth = GroveDayGrid.gap
        let size = (grid.bounds.height - 6 * gapWidth) / 7
        let pitch = size + gapWidth
        let weeks = Int(((grid.bounds.width + gapWidth) / pitch).rounded())
        #expect(size < 24, "the squares are \(size) pt: the window is not at its minimum")
        // In the gap under the first day of the week before last, which is wholly in the range.
        let gap = CGPoint(x: CGFloat(weeks - 2) * pitch + size / 2, y: size + gapWidth / 2)
        await host.click(grid, at: grid.isFlipped ? gap : CGPoint(x: gap.x, y: grid.bounds.height - gap.y))
        #expect(await host.settle { host.node { $0.text == prompt } == nil }, "a click between two days picked neither")
    }

    // MARK: Space on the stage

    @Test("Space starts the Dictate stage only from the stage, and stops a recording from anywhere")
    func spaceStartsOnlyFromTheStage() async throws {
        var starts = 0
        var stops = 0
        let controller = F.sampleController()
        let host = TransitionHost(controller: controller) {
            GroveRenderHarness.window(.today, controller: controller) {
                VStack {
                    GroveTodayHeader(status: .ready, shortcuts: TodayShortcuts(optionHold: true, handsFreeKey: nil),
                                     onStart: { starts += 1 })
                    Spacer()
                }
            }
        }
        defer { host.close() }
        await host.settle { host.node(named: "Dictate") != nil }
        host.window.makeKey()
        await host.keyPress(49, characters: " ")
        #expect(starts == 0, "Space started a dictation from outside the stage")

        let plate = TransitionHost(controller: controller) {
            GroveRenderHarness.window(.today, controller: controller) {
                GroveRecordingPlate(mode: .listening(startedAt: Date()), targetApp: "Mail", onStop: { stops += 1 })
            }
        }
        defer { plate.close() }
        await plate.settle { plate.node(named: "Stop and insert") != nil }
        plate.window.makeKey()
        await plate.keyPress(49, characters: " ")
        #expect(stops == 1, "Space did not stop the recording")
    }
}

/// History as the window holds it, with its own search text, so typing in the search filters
/// the list and shows Clear search.
struct SearchableGroveHistory: View {
    var selected: UUID?
    var filter: HistoryFilter = .all
    @State private var query = ""

    var body: some View {
        GroveHistoryView(searchQuery: $query, initialSelectedEntryID: selected, initialFilter: filter)
    }
}
