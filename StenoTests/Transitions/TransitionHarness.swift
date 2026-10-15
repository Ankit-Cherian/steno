import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Live inputs a transition test flips while its view stays on screen: what a parent passes
/// down, changed without recreating the view.
@MainActor
final class TransitionKnobs: ObservableObject {
    @Published var scheme: ColorScheme = .light
    @Published var increasedContrast = false
    /// On by default so a test reads still frames; off to see the level move the quill and bars.
    @Published var reduceMotion = true
    /// The app's text-size setting, for larger-text checks.
    @Published var textSize: DynamicTypeSize = .large
    /// The window's content size, which `TransitionHost.resize(to:)` changes.
    @Published var size: CGSize = GroveRenderHarness.windowSize
}

/// A borderless window that can still take the keyboard, so a test can type into a field.
final class TransitionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Hosts a production view in a real window, ordered in so AppKit runs its display and layout
/// passes, drives it the way a person or VoiceOver does (buttons by their accessible names,
/// AppKit controls found in the view tree, typing through the field editor), and reads back
/// what is drawn.
///
/// Every test of the transition suites creates one, flips state through the interface, waits
/// for the result with `settle(until:)`, and asserts on the views AppKit laid out.
///
/// The window is transparent and ignores the mouse, so a test run never covers or takes clicks
/// from what is on the screen; it is still a window the window server draws.
@MainActor
final class TransitionHost {
    let window: TransitionWindow
    let hosting: NSHostingView<AnyView>
    let knobs: TransitionKnobs
    let controller: DictationController?
    /// The popovers shown while the host is up, oldest first, as AppKit announced them.
    private(set) var shownPopovers: [NSPopover] = []
    private var popoverObserver: NSObjectProtocol?

    init<Content: View>(size: CGSize = GroveRenderHarness.windowSize, controller: DictationController?,
                        knobs: TransitionKnobs = TransitionKnobs(), @ViewBuilder content: () -> Content) {
        AppFontRegistry.registerIfNeeded()
        Self.enableAccessibilityTree()
        self.knobs = knobs
        self.controller = controller
        knobs.size = size
        var root = AnyView(TransitionRoot(knobs: knobs, content: content()))
        if let controller { root = AnyView(root.environmentObject(controller)) }
        hosting = NSHostingView(rootView: root)
        // Far from every display, so nothing shows even for the one frame before alpha applies.
        window = TransitionWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        popoverObserver = NotificationCenter.default.addObserver(forName: NSPopover.willShowNotification, object: nil, queue: nil) {
            [weak self] note in
            guard let popover = note.object as? NSPopover else { return }
            MainActor.assumeIsolated { self?.shownPopovers.append(popover) }
        }
    }

    /// Resizes the window and its content to `size`, as dragging its corner does, and lets the
    /// layout catch up.
    func resize(to size: CGSize) async {
        knobs.size = size
        window.setContentSize(size)
        hosting.frame = CGRect(origin: .zero, size: size)
        await settle()
    }

    /// Takes the window down. Call it in `defer`.
    func close() {
        if let popoverObserver { NotificationCenter.default.removeObserver(popoverObserver) }
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    // MARK: Settling

    /// Lets SwiftUI, AppKit layout and the run loop catch up once.
    func pump(_ duration: Duration = .milliseconds(16)) async {
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try? await Task.sleep(for: duration)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    /// Pumps until `condition` holds, for at most `timeout`. Returns whether it held, so a test
    /// can `#expect` it with its own message. The default is the hang-guard ceiling, which only
    /// a broken behavior reaches.
    @discardableResult
    func settle(timeout: Duration = hangGuardCeiling, until condition: @MainActor () -> Bool = { true }) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        // Always give SwiftUI a few passes, so an update scheduled for the next turn lands.
        for _ in 0..<3 { await pump() }
        while clock.now < deadline {
            if condition() { return true }
            await pump(.milliseconds(10))
        }
        return condition()
    }

    // MARK: Accessibility

    /// SwiftUI builds its accessibility tree only once an assistive client has asked for it.
    /// This sets the attributes such a client sets on the app, so the tree is there to walk.
    static func enableAccessibilityTree() {
        for name in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: name))
        }
    }

    /// One element of the window's accessibility tree, as VoiceOver reads it. SwiftUI's own
    /// elements answer the NSAccessibility methods without declaring the protocol, so they are
    /// asked through the Objective-C runtime.
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
        /// What VoiceOver says for a slider's value, which is itself a number.
        var valueDescription: String { string(NSSelectorFromString("accessibilityValueDescription")) }
        var identifier: String { string(#selector(NSAccessibilityProtocol.accessibilityIdentifier)) }
        var role: String { string(#selector(NSAccessibilityProtocol.accessibilityRole)) }
        var subrole: String { string(#selector(NSAccessibilityProtocol.accessibilitySubrole)) }
        /// The hint VoiceOver reads after the name: what the element does.
        var help: String { string(NSSelectorFromString("accessibilityHelp")) }
        var isSelected: Bool { flag(#selector(NSAccessibilityProtocol.isAccessibilitySelected)) }
        var isEnabled: Bool { flag(#selector(NSAccessibilityProtocol.isAccessibilityEnabled)) }
        /// A checkbox's or switch's value: 1 on, 0 off.
        var number: Int? {
            let selector = #selector(NSAccessibilityProtocol.accessibilityValue)
            guard object.responds(to: selector) else { return nil }
            return (object.perform(selector)?.takeUnretainedValue() as? NSNumber)?.intValue
        }
        /// Where the element is on screen, as assistive technology sees it.
        var screenFrame: CGRect {
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector) else { return .zero }
            typealias Call = @convention(c) (NSObject, Selector) -> CGRect
            return unsafeBitCast(object.method(for: selector), to: Call.self)(object, selector)
        }
        /// The name a person hears: the label, else the title.
        var name: String { label.isEmpty ? title : label }
        /// What static text says: its value, else its name.
        var text: String { value.isEmpty ? name : value }

        var children: [NSObject] {
            let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
            guard object.responds(to: selector) else { return [] }
            return (object.perform(selector)?.takeUnretainedValue() as? [Any])?.compactMap { $0 as? NSObject } ?? []
        }

        @discardableResult
        func press() -> Bool { flag(#selector(NSAccessibilityProtocol.accessibilityPerformPress)) }

        /// Whether the keyboard focus can land here: what Tab reaches with Full Keyboard Access,
        /// and what VoiceOver can move the keyboard focus to.
        var isFocusTarget: Bool {
            let allowed = NSSelectorFromString("isAccessibilitySelectorAllowed:")
            guard object.responds(to: allowed) else { return false }
            typealias Call = @convention(c) (NSObject, Selector, Selector) -> Bool
            return unsafeBitCast(object.method(for: allowed), to: Call.self)(object, allowed, NSSelectorFromString("setAccessibilityFocused:"))
        }

        /// Moves the keyboard focus here, as VoiceOver does when it follows its cursor: SwiftUI
        /// gives the control its focus, and an AppKit control becomes the first responder.
        func focus() {
            object.setValue(true, forKey: "accessibilityFocused")
        }

        /// The names of the element's own VoiceOver actions (Control-Option-Command-Space).
        var customActionNames: [String] { customActions.map(\.name) }

        private var customActions: [NSAccessibilityCustomAction] {
            let selector = NSSelectorFromString("accessibilityCustomActions")
            guard object.responds(to: selector) else { return [] }
            return (object.perform(selector)?.takeUnretainedValue() as? [NSAccessibilityCustomAction]) ?? []
        }

        /// Performs the element's VoiceOver action named `name`, as choosing it from VoiceOver's
        /// actions menu does. False when there is no such action.
        @discardableResult
        func perform(action name: String) -> Bool {
            guard let action = customActions.first(where: { $0.name == name }) else { return false }
            if let handler = action.handler { return handler() }
            guard let target = action.target as? NSObject, let selector = action.selector else { return false }
            target.perform(selector, with: action)
            return true
        }
    }

    /// Runs `body` with Full Keyboard Access on, as AppKit sees it, then puts the setting back
    /// before anything else runs: AppKit controls take the first responder only with it on.
    /// `body` must not suspend.
    static func withFullKeyboardAccess(_ body: () -> Void) {
        let method = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isFullKeyboardAccessEnabled))!
        let on: @convention(block) (AnyObject) -> Bool = { _ in true }
        let original = method_setImplementation(method, imp_implementationWithBlock(on))
        defer { method_setImplementation(method, original) }
        body()
    }

    /// Moves the keyboard focus to `node`, as Tab does with Full Keyboard Access on. A SwiftUI
    /// control takes it from VoiceOver's focus; an AppKit control that does not, a SwiftUI menu's
    /// button among them, is made the first responder, which is what Tab does to it.
    func moveKeyboardFocus(to node: Node) {
        Self.withFullKeyboardAccess { node.focus() }
        guard window.firstResponder === window else { return }
        let target = node.screenFrame
        let control = views(NSControl.self).first { view in
            guard view.window === window else { return false }
            let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
            return frame.intersection(target).width * frame.intersection(target).height > 0.5 * frame.width * frame.height
        }
        if let control { Self.withFullKeyboardAccess { _ = window.makeFirstResponder(control) } }
    }

    /// The share of the drawing around `node`, 5 pt either side, that changes when the keyboard
    /// focus moves to it: the focus ring, for a control that draws one.
    func focusRingChange(_ node: Node) async -> Double {
        let rect = hostingRect(fromScreen: node.screenFrame).insetBy(dx: -5, dy: -5)
        // From no focus at all, so a control that already had it still shows a change.
        window.makeFirstResponder(nil)
        await settle()
        guard let before = bitmap(of: rect) else { return 0 }
        moveKeyboardFocus(to: node)
        await settle()
        await pump(.milliseconds(30))
        guard let after = bitmap(of: rect) else { return 0 }
        return Self.difference(before, after)
    }

    /// The hosting view and the content of every window attached to it, such as a popover.
    private var roots: [NSView] {
        [hosting] + popoverWindows.compactMap(\.contentView)
    }

    /// The windows on screen attached to the host window: its open popovers.
    var popoverWindows: [NSWindow] { (window.childWindows ?? []).filter(\.isVisible) }

    /// Every element under the hosting view and its popovers, or under `root`, depth first.
    func nodes(under root: Node? = nil) -> [Node] {
        var result: [Node] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: NSObject, depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object)
            if depth > 0 { result.append(node) }
            for child in node.children { walk(child, depth: depth + 1) }
        }
        if let root {
            walk(root.object, depth: 0)
        } else {
            for view in roots { walk(view, depth: 0) }
        }
        return result
    }

    /// Presses the button inside the group named `group` whose name contains `text`, as a
    /// click on a list row does.
    func pressRow(containing text: String, in group: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let container = try #require(node { $0.name == group }, "No group “\(group)”", sourceLocation: sourceLocation)
        let row = try #require(nodes(under: container).first { $0.role == "AXButton" && $0.name.contains(text) },
                               "No row with “\(text)” in \(group)", sourceLocation: sourceLocation)
        #expect(row.press(), sourceLocation: sourceLocation)
        await settle()
    }

    func nodes(named name: String) -> [Node] { nodes().filter { $0.name == name } }

    func node(named name: String) -> Node? { nodes(named: name).first }

    func node(identifier: String) -> Node? { nodes().first { $0.identifier == identifier } }

    func node(where matches: (Node) -> Bool) -> Node? { nodes().first(where: matches) }

    /// Presses the button VoiceOver names `name`, then lets the window settle once.
    func press(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let found = try #require(self.node(named: name), "No element named “\(name)”. Names: \(names())", sourceLocation: sourceLocation)
        #expect(found.press(), "“\(name)” did not accept a press", sourceLocation: sourceLocation)
        await settle()
    }

    /// Presses the first element whose name starts with `prefix`.
    func press(prefix: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let found = try #require(self.node { $0.name.hasPrefix(prefix) }, "No element starting “\(prefix)”. Names: \(names())",
                                 sourceLocation: sourceLocation)
        #expect(found.press(), "“\(found.name)” did not accept a press", sourceLocation: sourceLocation)
        await settle()
    }

    /// The accessible names on screen, for failure messages.
    func names() -> [String] { nodes().map(\.name).filter { !$0.isEmpty } }

    // MARK: AppKit views

    /// Every view of type `T` in the window and its popovers, in tree order.
    func views<T: NSView>(_ type: T.Type) -> [T] {
        var found: [T] = []
        func walk(_ view: NSView) {
            if let match = view as? T { found.append(match) }
            view.subviews.forEach(walk)
        }
        roots.forEach(walk)
        return found
    }

    /// The voice quills on screen. The app links its own copy of StenoKit, so its quill class is
    /// not the one this bundle sees, and the views are found by name.
    func quills() -> [NSView] {
        views(NSView.self).filter { NSStringFromClass(Swift.type(of: $0)).hasSuffix("BrandMarkView") }
    }

    /// The path the quill's outer vane is drawn with now: the barbs that follow the voice.
    static func outerVane(of quill: NSView) -> CGPath? {
        // container > barb gradient > its mask > [inner vane, outer vane]
        let container = quill.layer?.sublayers?.first
        let mask = container?.sublayers?.first?.mask
        return (mask?.sublayers?.last as? CAShapeLayer)?.path
    }

    /// The colours of the quill's barbs, as drawn.
    static func barbColors(of quill: NSView) -> [CGColor] {
        (quill.layer?.sublayers?.first?.sublayers?.first as? CAGradientLayer)?.colors as? [CGColor] ?? []
    }

    /// The dictation text views, longest text first.
    func transcriptViews() -> [TranscriptNSTextView] {
        views(TranscriptNSTextView.self).sorted { ($0.textStorage?.length ?? 0) > ($1.textStorage?.length ?? 0) }
    }

    /// Picks `title` from the pull-down menu whose button is found by `matching`, as choosing
    /// the item with the mouse does, without running the menu's modal tracking. SwiftUI fills
    /// a menu as it opens, so each candidate is asked to fill itself first.
    func choose(menuItem title: String, in matching: (NSPopUpButton) -> Bool = { _ in true },
                sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for button in views(NSPopUpButton.self).filter(matching) {
            guard let menu = button.menu else { continue }
            // A SwiftUI menu builds its items when the cell says it is about to show them.
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
            await settle()
            return
        }
        Issue.record("No menu with “\(title)”", sourceLocation: sourceLocation)
    }

    /// Selects `label` in the segmented control that holds it.
    func selectSegment(_ label: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let control = try #require(views(NSSegmentedControl.self).first { control in
            (0..<control.segmentCount).contains { control.label(forSegment: $0) == label }
        }, "No segment “\(label)”", sourceLocation: sourceLocation)
        let index = try #require((0..<control.segmentCount).first { control.label(forSegment: $0) == label })
        control.selectedSegment = index
        if let action = control.action { NSApp.sendAction(action, to: control.target, from: control) }
        await settle()
    }

    /// Types `text` into the field whose placeholder or accessible label is `field`, through the
    /// field editor, as the keyboard does.
    func type(_ text: String, into field: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        // SwiftUI names its fields for accessibility once the tree has been read.
        _ = nodes()
        let target = try #require(views(NSTextField.self).first {
            $0.isEditable && ($0.placeholderString == field || $0.accessibilityLabel() == field)
        }, "No text field “\(field)”", sourceLocation: sourceLocation)
        let owner = try #require(target.window, sourceLocation: sourceLocation)
        owner.makeKey()
        #expect(owner.makeFirstResponder(target), sourceLocation: sourceLocation)
        let editor = try #require(owner.fieldEditor(false, for: target) as? NSTextView, sourceLocation: sourceLocation)
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            await pump(.milliseconds(1))
        }
        await settle()
    }

    /// Empties the field being edited, as Select All and Delete do.
    func clearField(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let responder = ([window] + (window.childWindows ?? [])).compactMap { $0.firstResponder as? NSTextView }.first
        let editor = try #require(responder, "No field is being edited", sourceLocation: sourceLocation)
        editor.selectAll(nil)
        editor.deleteBackward(nil)
        await settle()
    }

    /// `rect` from screen coordinates to the hosting view's, which are flipped: y grows down.
    func hostingRect(fromScreen rect: CGRect) -> CGRect {
        hosting.convert(window.convertFromScreen(rect), from: nil)
    }

    /// Clicks `point` (in `view`'s coordinates) with a left mouse down and up sent to the view.
    func click(_ view: NSView, at point: CGPoint) async {
        let inWindow = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseDown ? 1 : 0) {
                type == .leftMouseDown ? view.mouseDown(with: event) : view.mouseUp(with: event)
            }
        }
        await settle()
    }

    /// Presses a key the way the keyboard does: key equivalents first (a default or cancel
    /// button), then the first responder. An open popover takes the key, as it is the key window.
    func keyPress(_ keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) async {
        let target = popoverWindows.last ?? window
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: target.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return }
        if !target.performKeyEquivalent(with: event) { target.sendEvent(event) }
        await settle()
    }

    /// Sends a key press to the window's first responder.
    func key(_ keyCode: UInt16, characters: String = "") async {
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) {
            window.firstResponder?.keyDown(with: event)
        }
        await settle()
    }

    /// The window drawn from the views' current state. This shows any input a view failed to
    /// take on an update (a colour, a line limit, a mark), since the view draws from what it
    /// holds. It redraws every view, so it cannot show a view that took the input but never
    /// asked to be redrawn; the window server's copy is not readable from a test.
    func bitmap() -> NSBitmapImageRep? {
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    /// `rect` of the window (in the hosting view's coordinates) drawn from the views' current
    /// state: cheaper than the whole window, so frames can be read close together.
    func bitmap(of rect: CGRect) -> NSBitmapImageRep? {
        hosting.layoutSubtreeIfNeeded()
        let rect = rect.intersection(hosting.bounds)
        guard !rect.isEmpty, let bitmap = hosting.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        hosting.cacheDisplay(in: rect, to: bitmap)
        return bitmap
    }

    /// The share of pixels that differ by more than a rounding step between two images of the
    /// same size: 0 for the same drawing, 1 for nothing in common.
    static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 1 }
        let a = rgba(a), b = rgba(b)
        let pixels = a.count / 4
        var differing = 0
        a.withUnsafeBufferPointer { p in
            b.withUnsafeBufferPointer { q in
                for pixel in 0..<pixels {
                    let i = pixel * 4
                    var delta: Int32 = 0
                    for channel in 0..<4 { delta = max(delta, abs(Int32(p[i + channel]) - Int32(q[i + channel]))) }
                    if delta > 3 { differing += 1 }
                }
            }
        }
        return Double(differing) / Double(max(1, pixels))
    }

    /// The image redrawn as 8-bit sRGB RGBA at half its pixel size (one sample per point on a
    /// Retina render), so two images compare byte for byte and a debug build compares quickly.
    private static func rgba(_ image: NSBitmapImageRep) -> [UInt8] {
        let width = max(1, image.pixelsWide / 2), height = max(1, image.pixelsHigh / 2)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let cgImage = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return bytes }
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.interpolationQuality = .none
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    /// The colour at `point` of the window as drawn now, in the hosting view's coordinates.
    func color(at point: CGPoint) -> NSColor? {
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / max(1, hosting.bounds.width)
        let y = hosting.isFlipped ? point.y : hosting.bounds.height - point.y
        return bitmap.colorAt(x: Int(point.x * scale), y: Int(y * scale))
    }
}

/// The environment the render tests pin, with the knobs a transition test flips.
private struct TransitionRoot<Content: View>: View {
    @ObservedObject var knobs: TransitionKnobs
    let content: Content

    var body: some View {
        content
            .environment(\.colorScheme, knobs.scheme)
            .environment(\._colorSchemeContrast, knobs.increasedContrast ? .increased : .standard)
            .environment(\.drawsWindowChromeInline, true)
            .environment(\._accessibilityReduceMotion, knobs.reduceMotion)
            .environment(\.dynamicTypeSize, knobs.textSize)
            // The text size the knob sets, whatever this Mac's own setting is.
            .environment(\.systemTextSize, SystemTextSize(read: { SystemTextSize.baselineBodyPointSize }))
            .frame(width: knobs.size.width, height: knobs.size.height)
    }
}

// MARK: - Reading text as drawn

/// What a dictation text view laid out, read from its TextKit stack.
@MainActor
struct DrawnText {
    let characters: Int
    /// Glyphs placed in the container. Fewer than the text's glyphs means words were cut.
    let laidOutGlyphs: Int
    let totalGlyphs: Int
    let lines: Int
    /// Whether the last line ends in an ellipsis.
    let isTruncated: Bool
    /// The height the laid-out lines need, and the height the view has.
    let usedHeight: CGFloat
    let viewHeight: CGFloat
    /// Where the last character is drawn, in the view.
    let lastCharacterRect: CGRect?
    let viewBounds: CGRect

    init(_ view: TranscriptNSTextView) {
        let layout = view.layoutManager!
        let container = view.textContainer!
        let length = view.textStorage?.length ?? 0
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(for: container)
        var lines = 0
        var truncated = false
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, range, _ in
            lines += 1
            if layout.truncatedGlyphRange(inLineFragmentForGlyphAt: range.location).location != NSNotFound { truncated = true }
        }
        characters = length
        laidOutGlyphs = glyphs.length
        totalGlyphs = layout.numberOfGlyphs
        self.lines = lines
        isTruncated = truncated
        usedHeight = layout.usedRect(for: container).height
        viewHeight = view.bounds.height
        viewBounds = view.bounds
        lastCharacterRect = length > 0 ? view.rect(for: NSRange(location: length - 1, length: 1)) : nil
    }

    /// Every word is laid out, nothing ends in an ellipsis, and the last character sits inside
    /// the view's bounds.
    var showsWholeText: Bool {
        laidOutGlyphs == totalGlyphs && !isTruncated && usedHeight <= viewHeight + 1
            && (lastCharacterRect.map { viewBounds.insetBy(dx: -1, dy: -1).contains($0) } ?? true)
    }
}

// MARK: - Fixtures

@MainActor
enum TransitionFixtures {
    /// A dictation long enough for the 12-line cap: about 1,400 characters.
    static let longText = String(repeating: "The updated agenda goes to Dana before lunch so everyone has time to read it. ", count: 18)
        .trimmingCharacters(in: .whitespaces) + " Last words here."

    static func entry(_ text: String, minutesAgo: Double = 0, status: InsertionStatus = .inserted, id: UUID = UUID(),
                      raw: String? = nil, original: String? = nil) -> TranscriptEntry {
        var entry = TranscriptEntry(id: id, createdAt: Date().addingTimeInterval(-minutesAgo * 60), appBundleID: "com.example.preview",
                                    rawText: raw ?? text, cleanText: text, durationMS: 12_000, audioURL: nil, insertionStatus: status)
        entry.originalCleanText = original
        return entry
    }

    /// The isolated sample controller of the render tests, with `entries` as its History.
    static func sampleController(_ entries: [TranscriptEntry]? = nil) -> DictationController {
        let controller = GroveRenderHarness.sampleController(.light)
        if let entries { controller.recentEntries = entries }
        return controller
    }
}
