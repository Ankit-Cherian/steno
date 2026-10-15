import AppKit
import ApplicationServices
import Combine
import StenoKit
import SwiftUI

// MARK: - Panel

/// The Grove menu's window: borderless, above other windows, and not key until the keyboard is
/// used, so opening it never takes focus from the app being dictated into.
final class GroveMenuPanel: NSPanel {
    /// Off until the keyboard is used. While off the panel cannot become key.
    var acceptsKeyboard = false
    weak var state: GroveMenuState?

    init(contentView: NSView) {
        super.init(
            contentRect: CGRect(origin: .zero, size: contentView.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.contentView = contentView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        isMovable = false
        animationBehavior = .none
        setAccessibilityLabel("Steno")
    }

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        guard let key = GroveMenuKey(event) else { return }
        state?.handle(key)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control),
              let key = GroveMenuKey(event), case .character = key else { return false }
        return state?.handle(key) ?? false
    }

    override func cancelOperation(_ sender: Any?) {
        state?.handle(.escape)
    }
}

// MARK: - Content container

/// Hosts the SwiftUI view and owns what makes the panel a menu: pointer tracking, hit testing
/// by row, and the menu and menu item accessibility roles.
@MainActor
final class GroveMenuContainerView: NSView {
    let state: GroveMenuState
    let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    /// The blur under the forest tint. Hidden under Reduce Transparency, which leaves solid forest.
    let effectView = NSVisualEffectView()
    private var elements: [String: GroveMenuAccessibilityElement] = [:]
    private var statusElement: NSAccessibilityElement?
    private var pressedID: String?

    init(state: GroveMenuState) {
        self.state = state
        super.init(frame: .zero)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = Self.roundedMask(radius: GroveMenuView.cornerRadius)
        effectView.autoresizingMask = [.width, .height]
        addSubview(effectView)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// The panel takes every pointer event itself, so rows are found by position.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Pointer

    override func mouseMoved(with event: NSEvent) {
        state.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        state.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        state.pointerLeft()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        state.pointerMoved(to: point)
        pressedID = state.row(at: point)?.id
    }

    override func mouseDragged(with event: NSEvent) {
        state.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { pressedID = nil }
        guard let pressedID, state.row(at: point)?.id == pressedID else { return }
        state.click(at: point)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .menu }
    override func accessibilityLabel() -> String? { "Steno" }

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = []
        let status = statusElement ?? {
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityParent(self)
            statusElement = element
            return element
        }()
        status.setAccessibilityLabel(statusDescription())
        status.setAccessibilityFrame(screenRect(for: state.frames["primary"] ?? CGRect(x: 0, y: 0, width: bounds.width, height: 1)))
        children.append(status)

        var live: [String: GroveMenuAccessibilityElement] = [:]
        for row in state.layout.targets {
            let element = elements[row.id] ?? GroveMenuAccessibilityElement(rowID: row.id, state: state)
            element.configure(row: row, container: self, frame: state.frames[row.id].map(screenRect(for:)) ?? .zero,
                              isHighlighted: state.highlightedID == row.id)
            live[row.id] = element
            children.append(element)
        }
        elements = live
        return children
    }

    /// What Steno is doing, in words, as the first thing VoiceOver reads.
    func statusDescription(now: Date = Date()) -> String {
        let snapshot = state.snapshot
        switch snapshot.iconState {
        case .recording:
            let elapsed = snapshot.recordingStartedAt.map { QuillStatusPillState.elapsed(Int(now.timeIntervalSince($0))) }
            return [state.title, elapsed, state.statusHint].compactMap { $0 }.joined(separator: ", ")
        case .transcribing: return "Transcribing, on this Mac"
        case .attention, .idle: return state.title + ", " + state.statusHint
        }
    }

    private func screenRect(for rect: CGRect) -> CGRect {
        let inWindow = convert(rect, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }
}

/// One menu item as VoiceOver sees it.
@MainActor
final class GroveMenuAccessibilityElement: NSAccessibilityElement {
    private let rowID: String
    private weak let state: GroveMenuState?

    init(rowID: String, state: GroveMenuState) {
        self.rowID = rowID
        self.state = state
        super.init()
        setAccessibilityRole(.menuItem)
    }

    func configure(row: GroveMenuRow, container: NSView, frame: CGRect, isHighlighted: Bool) {
        setAccessibilityParent(container)
        setAccessibilityLabel(row.accessibilityLabel)
        setAccessibilityHelp(row.accessibilityHint)
        setAccessibilityEnabled(row.isEnabled)
        setAccessibilityFrame(frame)
        setAccessibilityFocused(isHighlighted)
        // An element is reused for its row while the panel is open, so every state is set both
        // ways: a microphone that stops being the chosen one must stop reading as selected.
        if case .disclosure = row.behaviour {
            setAccessibilityExpanded(row.isChecked)
            setAccessibilityValue(nil)
            setAccessibilitySelected(false)
        } else {
            setAccessibilityExpanded(false)
            setAccessibilityValue(row.isChecked ? 1 : nil)
            setAccessibilitySelected(row.isChecked)
        }
    }

    /// Nonisolated like its `NSAccessibilityElement` original, but AppKit delivers accessibility
    /// actions on the main thread. The element is not sendable, so only its fields are captured.
    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated { [state, rowID] in
            guard let state, let row = state.layout.row(withID: rowID), row.isEnabled else { return false }
            state.activate(row)
            return true
        }
    }
}

// MARK: - Presenter

/// Shows the Grove panel under the status item and closes it when it should go: an outside
/// click, Esc, another app coming forward, a Space or screen change, or an item running.
@MainActor
final class GroveMenuPresenter {
    let state = GroveMenuState()
    private(set) var panel: GroveMenuPanel
    private let container: GroveMenuContainerView
    private(set) var isShown = false
    /// Called with `true` as the panel opens and `false` as it closes.
    var onVisibilityChange: ((Bool) -> Void)?

    private let installsMonitors: Bool
    private let reducesTransparency: () -> Bool
    private let present: (GroveMenuPanel) -> Void
    private let dismiss: (GroveMenuPanel) -> Void
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var globalKeyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private weak var anchorWindow: NSWindow?
    private var anchorFrame = CGRect.zero
    private var screenFrame = CGRect.zero

    /// `installsMonitors: false` and no-op `present`/`dismiss` let tests drive the panel without
    /// showing a window or listening to the real mouse and keyboard.
    init(
        installsMonitors: Bool = true,
        reducesTransparency: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency },
        present: @escaping (GroveMenuPanel) -> Void = { $0.orderFrontRegardless() },
        dismiss: @escaping (GroveMenuPanel) -> Void = { $0.orderOut(nil) }
    ) {
        self.installsMonitors = installsMonitors
        self.reducesTransparency = reducesTransparency
        self.present = present
        self.dismiss = dismiss
        container = GroveMenuContainerView(state: state)
        panel = GroveMenuPanel(contentView: container)
        panel.state = state
        state.close = { [weak self] in self?.close() }
        // SwiftUI redraws on the next turn, so fit again once it has.
        state.contentDidChange = { [weak self] in
            self?.fit()
            DispatchQueue.main.async { self?.fit() }
        }
    }

    /// Opens the panel under the status item. `keyboardInitiated` is true when the item was
    /// activated from the keyboard or by VoiceOver: only then does the panel take key status.
    func show(
        snapshot: MenuBarSnapshot,
        targetAppName: String?,
        accent: StenoAccentStyle,
        appearance: NSAppearance?,
        statusItemFrame: CGRect,
        screenFrame: CGRect,
        anchorWindow: NSWindow?,
        keyboardInitiated: Bool
    ) {
        if isShown { close() }
        self.anchorFrame = statusItemFrame
        self.screenFrame = screenFrame
        self.anchorWindow = anchorWindow
        panel.appearance = appearance
        container.effectView.isHidden = reducesTransparency()
        container.hosting.rootView = AnyView(GroveMenuView(state: state).groveTheme(accentStyle: accent))
        state.reset(snapshot: snapshot, targetAppName: targetAppName, usesKeyboard: keyboardInitiated)
        fit()
        isShown = true
        panel.acceptsKeyboard = keyboardInitiated
        present(panel)
        if keyboardInitiated { panel.makeKey() }
        installMonitors()
        onVisibilityChange?(true)
        // The shadow follows the drawn shape, so refresh it once SwiftUI has drawn.
        DispatchQueue.main.async { [weak self] in self?.panel.invalidateShadow() }
    }

    func close() {
        guard isShown else { return }
        isShown = false
        removeMonitors()
        panel.acceptsKeyboard = false
        dismiss(panel)
        onVisibilityChange?(false)
    }

    /// Re-reads the controller while the panel is open, for example when recording starts.
    func refresh(snapshot: MenuBarSnapshot, targetAppName: String?) {
        guard isShown else { return }
        state.update(snapshot: snapshot, targetAppName: targetAppName)
    }

    /// The panel's size follows its content; its top edge stays under the menu bar.
    func fit() {
        container.hosting.layoutSubtreeIfNeeded()
        var size = container.hosting.fittingSize
        size.width = GroveMenuView.width
        guard size.height > 0 else { return }
        container.setFrameSize(size)
        container.hosting.frame = CGRect(origin: .zero, size: size)
        let frame = GroveMenuPlacement.frame(panelSize: size, statusItemFrame: anchorFrame, screenFrame: screenFrame)
        panel.setFrame(frame, display: isShown)
        panel.invalidateShadow()
    }

    /// Makes the panel key so the keyboard reaches it. Only the keyboard asks for this.
    func enableKeyboard() {
        guard isShown, !panel.acceptsKeyboard else { return }
        panel.acceptsKeyboard = true
        panel.makeKey()
    }

    // MARK: Close rules

    private func installMonitors() {
        removeMonitors()
        if installsMonitors {
            let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDown) { [weak self] event in
                MainActor.assumeIsolated { self?.handleLocalMouseDown(in: event.window) }
                return event
            }
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDown) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
            // Keys typed in another app reach this process only when it is trusted for Accessibility.
            // Esc closes; an arrow hands the panel the keyboard; anything else means the user went back
            // to what they were doing.
            if AXIsProcessTrusted() {
                globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    let keyCode = event.keyCode
                    MainActor.assumeIsolated { self?.handleGlobalKeyDown(keyCode: keyCode) }
                }
            }
        }
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSApplication.didChangeScreenParametersNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.close() }
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    private func removeMonitors() {
        for monitor in [localMouseMonitor, globalMouseMonitor, globalKeyMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        globalKeyMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        workspaceObservers = []
    }

    /// A click in this app's windows. Clicks in the panel are its own; a click on the status
    /// item is left to its button, which toggles the panel.
    func handleLocalMouseDown(in window: NSWindow?) {
        guard window !== panel else { return }
        if let anchorWindow, window === anchorWindow { return }
        close()
    }

    /// A key typed in another app, known only by its key code: what was typed is never read.
    func handleGlobalKeyDown(keyCode: UInt16) {
        switch GroveMenuGlobalKey(keyCode: keyCode) {
        case .escape:
            close()
        case .up:
            enableKeyboard()
            state.handle(.up)
        case .down:
            enableKeyboard()
            state.handle(.down)
        case .other:
            close()
        }
    }
}
