import AppKit
import Foundation
import StenoKit
import Testing
@testable import Steno

@Suite("Grove menu status item")
@MainActor
struct GroveMenuDesignSwitchTests {
    @Test("A status item click opens the panel and the next closes it")
    func clickTogglesPanel() {
        let presenter = GroveMenuPresenter(installsMonitors: false, present: { _ in }, dismiss: { _ in })
        let menuBar = MenuBarController(makePanelPresenter: { presenter })
        let controller = makeTestDictationController(hotkey: NoHotkey())
        defer { controller.teardown() }
        menuBar.observeInputLevel(of: controller)

        menuBar.toggleGrovePanel(keyboardInitiated: false)
        #expect(presenter.isShown)
        menuBar.toggleGrovePanel(keyboardInitiated: false)
        #expect(!presenter.isShown)
    }

    private final class NoHotkey: HotkeyService {
        var onPressToTalkStart: (() -> Void)?
        var onPressToTalkStop: (() -> Void)?
        var onToggleHandsFree: (() -> Void)?
        var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
        var isOptionPressToTalkEnabled = true
        var globalToggleKeyCode: UInt16?
        func start() {}
        func stop() {}
    }
}

@Suite("Grove menu panel window")
@MainActor
struct GroveMenuPanelWindowTests {
    private func makePresenter() -> GroveMenuPresenter {
        GroveMenuPresenter(installsMonitors: false, present: { _ in }, dismiss: { _ in })
    }

    private func show(_ presenter: GroveMenuPresenter, keyboard: Bool = false, anchorWindow: NSWindow? = nil) {
        presenter.show(
            snapshot: MenuBarSnapshot(entries: (0..<3).map { index in
                TranscriptEntry(createdAt: Date(), appBundleID: "com.example.app", rawText: "Dictation \(index)",
                    cleanText: "Dictation \(index)", durationMS: 1_000, audioURL: nil, insertionStatus: .inserted)
            }, canPasteLast: true),
            targetAppName: "Mail", accent: .dodger, appearance: NSAppearance(named: .darkAqua),
            statusItemFrame: CGRect(x: 1000, y: 876, width: 28, height: 24),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            anchorWindow: anchorWindow, keyboardInitiated: keyboard)
    }

    private func keyEvent(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code)!
    }

    // MARK: Window

    @Test("The panel is borderless, non-activating, above other windows, and not key until the keyboard is used")
    func windowTraits() {
        let presenter = makePresenter()
        let panel = presenter.panel
        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level == .popUpMenu)
        #expect(!panel.canBecomeMain)
        #expect(!panel.canBecomeKey)
        #expect(!panel.isOpaque)
        show(presenter)
        #expect(!panel.canBecomeKey)
        presenter.close()
        show(presenter, keyboard: true)
        #expect(panel.canBecomeKey)
        #expect(presenter.state.highlightedID == "primary")
        presenter.close()
        #expect(!panel.canBecomeKey)
    }

    @Test("A mouse opening highlights nothing; the first arrow key takes the keyboard and highlights the first row")
    func arrowTakesTheKeyboard() {
        let presenter = makePresenter()
        show(presenter)
        #expect(presenter.state.highlightedID == nil)
        presenter.handleGlobalKeyDown(keyCode: 125)
        #expect(presenter.panel.canBecomeKey)
        #expect(presenter.state.highlightedID == "primary")
        #expect(presenter.isShown)
        presenter.close()
    }

    @Test("The panel is sized to its content at 290 pt wide and placed under the item")
    func sizeAndPlacement() async throws {
        let presenter = makePresenter()
        show(presenter)
        let frame = presenter.panel.frame
        #expect(frame.width == GroveMenuView.width)
        #expect(frame.height > 200)
        #expect(frame.maxY == 876 - GroveMenuPlacement.gap)
        #expect(frame.minX == 1000)
        let before = frame.height
        presenter.state.toggle(.earlier)
        try await Task.sleep(for: .milliseconds(100))
        #expect(presenter.panel.frame.height > before)
        #expect(presenter.panel.frame.maxY == frame.maxY)
        presenter.close()
    }

    // MARK: Keys in the panel

    @Test("Arrow, Return and Esc reach the panel's state; key equivalents run through the window")
    func keysInPanel() {
        let presenter = makePresenter()
        var ran: [MenuBarAction] = []
        presenter.state.perform = { ran.append($0) }
        show(presenter, keyboard: true)
        let panel = presenter.panel
        panel.keyDown(with: keyEvent(125))
        #expect(presenter.state.highlightedID == "copy-last")
        panel.keyDown(with: keyEvent(36))
        #expect(ran == [.copyLatest])
        #expect(!presenter.isShown)

        show(presenter, keyboard: true)
        #expect(panel.performKeyEquivalent(with: keyEvent(31, characters: "o", modifiers: .command)))
        #expect(ran == [.copyLatest, .openSteno])
        #expect(!presenter.isShown)
        // Keys the panel has no use for are left to the rest of the app.
        show(presenter, keyboard: true)
        #expect(!panel.performKeyEquivalent(with: keyEvent(0, characters: "a", modifiers: .command)))
        #expect(!panel.performKeyEquivalent(with: keyEvent(0, characters: "a")))
        panel.keyDown(with: keyEvent(53))
        #expect(!presenter.isShown)
    }

    // MARK: Close rules

    @Test("Esc closes the panel")
    func escapeCloses() {
        let presenter = makePresenter()
        show(presenter)
        presenter.handleGlobalKeyDown(keyCode: 53)
        #expect(!presenter.isShown)
    }

    @Test("Other keys typed elsewhere close it")
    func otherKeysClose() {
        let presenter = makePresenter()
        show(presenter)
        presenter.handleGlobalKeyDown(keyCode: 0)
        #expect(!presenter.isShown)
    }

    @Test("A key typed in another app is handled by its key code alone: Esc closes, an arrow takes the keyboard, anything else closes")
    func globalKeysDependOnlyOnTheKeyCode() {
        for keyCode in UInt16(0)..<128 {
            let presenter = makePresenter()
            show(presenter)
            presenter.handleGlobalKeyDown(keyCode: keyCode)
            switch keyCode {
            case 125, 126:
                #expect(presenter.isShown, "key code \(keyCode)")
                #expect(presenter.panel.canBecomeKey, "key code \(keyCode)")
                #expect(presenter.state.highlightedID != nil, "key code \(keyCode)")
            default:
                #expect(!presenter.isShown, "key code \(keyCode)")
            }
            presenter.close()
        }
        #expect(GroveMenuGlobalKey(keyCode: 53) == .escape)
        #expect(GroveMenuGlobalKey(keyCode: 125) == .down)
        #expect(GroveMenuGlobalKey(keyCode: 126) == .up)
        #expect(GroveMenuGlobalKey(keyCode: 0) == .other)
        #expect(GroveMenuGlobalKey(keyCode: 36) == .other)
    }

    @Test("A click outside closes it; a click in the panel or on the status item doesn't")
    func outsideClick() {
        let presenter = makePresenter()
        let anchor = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        anchor.isReleasedWhenClosed = false
        let other = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        show(presenter, anchorWindow: anchor)
        presenter.handleLocalMouseDown(in: presenter.panel)
        #expect(presenter.isShown)
        presenter.handleLocalMouseDown(in: anchor)
        #expect(presenter.isShown)
        presenter.handleLocalMouseDown(in: other)
        #expect(!presenter.isShown)
        show(presenter)
        presenter.handleLocalMouseDown(in: nil)
        #expect(!presenter.isShown)
    }

    @Test("The panel closes when the app deactivates, another app comes forward, or the Space changes")
    func deactivationCloses() throws {
        let presenter = makePresenter()
        show(presenter)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(!presenter.isShown)

        show(presenter)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        #expect(!presenter.isShown)

        show(presenter)
        let finder = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: finder])
        #expect(!presenter.isShown)

        // Steno coming forward itself, for example from Open Steno, is not a reason to close first.
        show(presenter)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        #expect(presenter.isShown)
        presenter.close()
    }

    @Test("Reduce Transparency removes the blur and leaves solid forest")
    func reduceTransparency() {
        for reduces in [true, false] {
            let presenter = GroveMenuPresenter(installsMonitors: false, reducesTransparency: { reduces }, present: { _ in }, dismiss: { _ in })
            show(presenter)
            let container = presenter.panel.contentView as! GroveMenuContainerView
            #expect(container.effectView.isHidden == reduces)
            presenter.close()
        }
    }

    @Test("Closing reports visibility and a closed panel ignores further close rules")
    func visibilityCallback() {
        let presenter = makePresenter()
        var states: [Bool] = []
        presenter.onVisibilityChange = { states.append($0) }
        show(presenter)
        presenter.close()
        presenter.close()
        #expect(states == [true, false])
    }

    @Test("An item that runs closes the panel before it runs")
    func itemClosesFirst() {
        let presenter = makePresenter()
        var events: [String] = []
        presenter.onVisibilityChange = { events.append($0 ? "open" : "close") }
        presenter.state.perform = { events.append("run:\($0)") }
        show(presenter)
        presenter.state.activate(presenter.state.layout.row(withID: "quit")!)
        #expect(events == ["open", "close", "run:quit"])
    }

    // MARK: Accessibility

    @Test("VoiceOver sees a menu holding menu items, with the status read first")
    func accessibilityRoles() throws {
        let presenter = makePresenter()
        show(presenter)
        let container = presenter.panel.contentView as! GroveMenuContainerView
        #expect(container.accessibilityRole() == .menu)
        #expect(container.isAccessibilityElement())
        let children = try #require(container.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(children.first?.accessibilityRole() == .staticText)
        let items = children.dropFirst()
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.accessibilityRole() == .menuItem })
        #expect(items.map { $0.accessibilityLabel() ?? "" }.contains("Quit Steno"))
        #expect(items.map { $0.accessibilityLabel() ?? "" }.contains("Dictate"))
        #expect(items.allSatisfy { ($0.accessibilityParent() as AnyObject?) === container })
        presenter.close()
    }

    @Test("Pressing a menu item for VoiceOver runs it and closes the panel; a section reports whether it is open")
    func accessibilityPress() throws {
        let presenter = makePresenter()
        var ran: [MenuBarAction] = []
        presenter.state.perform = { ran.append($0) }
        show(presenter)
        let container = presenter.panel.contentView as! GroveMenuContainerView
        func item(_ label: String) throws -> NSAccessibilityElement {
            let children = try #require(container.accessibilityChildren() as? [NSAccessibilityElement])
            return try #require(children.first { $0.accessibilityLabel() == label })
        }
        let earlier = try item("Earlier")
        #expect(earlier.isAccessibilityExpanded() == false)
        #expect(earlier.accessibilityPerformPress())
        #expect(presenter.isShown)
        #expect(try item("Earlier").isAccessibilityExpanded() == true)

        #expect(try item("Quit Steno").accessibilityPerformPress())
        #expect(ran == [.quit])
        #expect(!presenter.isShown)
    }

    /// AppKit calls `accessibilityPerformPress()` from code that is not main-actor isolated.
    private nonisolated static func pressAsAppKitDoes(_ element: NSAccessibilityElement) -> Bool {
        element.accessibilityPerformPress()
    }

    @Test("A press from outside the main actor, as AppKit makes it, has run the item when it returns; an item that is off refuses")
    func accessibilityPressFromNonisolatedCaller() throws {
        let presenter = makePresenter()
        var ran: [MenuBarAction] = []
        presenter.state.perform = { ran.append($0) }
        presenter.show(
            snapshot: MenuBarSnapshot(), targetAppName: nil, accent: .dodger, appearance: nil,
            statusItemFrame: CGRect(x: 1000, y: 876, width: 28, height: 24),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), anchorWindow: nil, keyboardInitiated: false)
        let container = presenter.panel.contentView as! GroveMenuContainerView
        let children = try #require(container.accessibilityChildren() as? [NSAccessibilityElement])
        let copy = try #require(children.first { $0.accessibilityLabel() == "Copy Last Dictation" })
        let quit = try #require(children.first { $0.accessibilityLabel() == "Quit Steno" })

        #expect(Self.pressAsAppKitDoes(copy) == false)
        #expect(ran == [])
        #expect(presenter.isShown)

        #expect(Self.pressAsAppKitDoes(quit) == true)
        #expect(ran == [.quit])
        #expect(!presenter.isShown)
    }

    @Test("Items that are off say so and cannot be pressed")
    func accessibilityDisabled() throws {
        let presenter = makePresenter()
        presenter.show(
            snapshot: MenuBarSnapshot(), targetAppName: nil, accent: .dodger, appearance: nil,
            statusItemFrame: CGRect(x: 1000, y: 876, width: 28, height: 24),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), anchorWindow: nil, keyboardInitiated: false)
        let container = presenter.panel.contentView as! GroveMenuContainerView
        let children = try #require(container.accessibilityChildren() as? [NSAccessibilityElement])
        let copy = try #require(children.first { $0.accessibilityLabel() == "Copy Last Dictation" })
        #expect(copy.isAccessibilityEnabled() == false)
        #expect(!copy.accessibilityPerformPress())
        presenter.close()
    }

    @Test("The status line speaks recording, with the time, and where it is going")
    func statusDescription() throws {
        let presenter = makePresenter()
        let start = Date(timeIntervalSince1970: 1_000)
        presenter.show(
            snapshot: MenuBarSnapshot(lifecycle: .recordingHandsFree, isRecording: true, recordingStartedAt: start),
            targetAppName: "Mail", accent: .dodger, appearance: nil,
            statusItemFrame: CGRect(x: 1000, y: 876, width: 28, height: 24),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), anchorWindow: nil, keyboardInitiated: false)
        let container = try #require(presenter.panel.contentView as? GroveMenuContainerView)
        #expect(container.statusDescription(now: start.addingTimeInterval(14)) == "Listening, 0:14, into Mail")
        presenter.close()
    }

    @Test("At rest the status line speaks the header: the shortcut that is on, or why Steno can't dictate")
    func statusDescriptionAtRest() throws {
        let presenter = makePresenter()
        func spoken(_ snapshot: MenuBarSnapshot) throws -> String {
            presenter.show(
                snapshot: snapshot, targetAppName: nil, accent: .dodger, appearance: nil,
                statusItemFrame: CGRect(x: 1000, y: 876, width: 28, height: 24),
                screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), anchorWindow: nil, keyboardInitiated: false)
            return try #require(presenter.panel.contentView as? GroveMenuContainerView).statusDescription()
        }
        #expect(try spoken(MenuBarSnapshot()) == "Ready, hold Option to dictate")
        #expect(try spoken(MenuBarSnapshot(shortcuts: TodayShortcuts(optionHold: false, handsFreeKey: "F18")))
                == "Ready, press F18 to dictate")
        #expect(try spoken(MenuBarSnapshot(shortcuts: TodayShortcuts(optionHold: false, handsFreeKey: nil))) == "Ready, shortcuts are off")
        #expect(try spoken(MenuBarSnapshot(microphoneDenied: true)) == "Not ready, microphone access is off")
        presenter.close()
    }

    @Test("The panel's own content view draws the menu, as it will under the status item", arguments: [GroveMenuRenderingTests.Look.light, .dark])
    func renderRealPanel(look: GroveMenuRenderingTests.Look) async throws {
        AppFontRegistry.registerIfNeeded()
        let presenter = GroveMenuPresenter(installsMonitors: false, present: { _ in }, dismiss: { _ in })
        presenter.panel.colorSpace = .sRGB
        presenter.show(
            snapshot: GroveMenuRenderingTests.snapshot(for: .idle), targetAppName: nil, accent: .dodger,
            appearance: NSAppearance(named: look.scheme == .light ? .aqua : .darkAqua),
            statusItemFrame: CGRect(x: 1000, y: 876, width: 28, height: 24),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), anchorWindow: nil, keyboardInitiated: false)
        defer { presenter.close() }
        try await Task.sleep(for: .milliseconds(80))
        let view = try #require(presenter.panel.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: try GroveMenuRenderingTests.outputDirectory().appendingPathComponent("panel-\(look.rawValue).png"))
        #expect(data.count > 8_000)
        #expect(view.bounds.width == GroveMenuView.width)
    }
}
