import AppKit
import Combine
import StenoKit

// MARK: - Rows

/// The two sections that open inline instead of in a nested menu.
enum GroveMenuSection: String, Equatable, Sendable {
    case earlier
    case microphone
}

/// One thing the Grove panel can show and run. Built from `MenuBarMenuModel`, so the commands,
/// titles, enabled states and key equivalents stay in one place.
struct GroveMenuRow: Identifiable {
    enum Behaviour: Equatable {
        case action(MenuBarAction)
        /// Opens or closes a section in place.
        case disclosure(GroveMenuSection)
    }

    var id: String
    var title: String
    var behaviour: Behaviour
    var isEnabled = true
    var isChecked = false
    var keyEquivalent = ""
    var modifiers: NSEvent.ModifierFlags = []
    /// Shown in place of a title's shortcut, for example "⇧⌘C".
    var shortcut: String?
    /// What the row currently selects, shown quietly before its chevron: the microphone in use.
    var detail: String?
    /// A dictation row: its time, then its text.
    var entry: TranscriptEntry?
    /// Rows nested in an expanded section sit a little further in.
    var isNested = false
    /// Arrow keys visit it.
    var isNavigable = true
    var accessibilityLabel: String
    var accessibilityHint: String?

    var action: MenuBarAction? {
        if case .action(let action) = behaviour { action } else { nil }
    }
}

/// The panel's rows, grouped the way the panel spaces them.
struct GroveMenuLayout {
    /// Dictate, or Stop while recording; nil while transcribing.
    var primary: GroveMenuRow?
    /// "Turn On…" when microphone access is off.
    var attention: GroveMenuRow?
    /// Copy Last Dictation, drawn as the copy glyph on the latest dictation's card instead of as a
    /// row of its own.
    var latestCopy: GroveMenuRow?
    var latest: TranscriptEntry?
    /// Groups separated by spacing, never by rules.
    var groups: [[GroveMenuRow]] = []

    /// Every row the pointer or VoiceOver can reach, top to bottom.
    var targets: [GroveMenuRow] {
        [primary, attention, latestCopy].compactMap { $0 } + groups.flatMap { $0 }
    }

    /// The rows the arrow keys visit, top to bottom: the card's copy glyph sits where the
    /// Copy Last Dictation row used to.
    var navigable: [GroveMenuRow] { targets.filter(\.isNavigable) }

    func row(withID id: String) -> GroveMenuRow? { targets.first { $0.id == id } }

    static func make(snapshot: MenuBarSnapshot, expanded: Set<GroveMenuSection>) -> GroveMenuLayout {
        let items = MenuBarMenuModel.items(for: snapshot)
        func spec(_ action: MenuBarAction) -> MenuBarItemSpec? { items.first { $0.kind == .action(action) } }
        func row(_ action: MenuBarAction, id: String, hint: String? = nil) -> GroveMenuRow? {
            guard let spec = spec(action) else { return nil }
            return GroveMenuRow(
                id: id, title: spec.title, behaviour: .action(action), isEnabled: spec.isEnabled,
                keyEquivalent: spec.keyEquivalent, modifiers: spec.modifiers,
                shortcut: GroveMenuShortcut.text(key: spec.keyEquivalent, modifiers: spec.modifiers),
                accessibilityLabel: spec.title, accessibilityHint: hint
            )
        }

        var layout = GroveMenuLayout()
        // Copy Last and Paste Last act on a dictation History could not save, so it is the
        // latest and the card says so rather than showing the saved one before it.
        layout.latest = snapshot.hasUnsavedLast ? nil : snapshot.entries.first

        switch snapshot.iconState {
        case .recording:
            layout.primary = GroveMenuRow(
                id: "primary", title: "Stop", behaviour: .action(.stop),
                accessibilityLabel: "Stop and insert")
        case .transcribing:
            break
        case .idle, .attention:
            layout.primary = GroveMenuRow(
                id: "primary", title: "Dictate", behaviour: .action(.startDictation),
                isEnabled: !snapshot.microphoneDenied, accessibilityLabel: "Dictate",
                accessibilityHint: "Starts hands-free dictation")
        }
        if snapshot.microphoneDenied {
            layout.attention = GroveMenuRow(
                id: "turn-on-microphone", title: "Turn On…", behaviour: .action(.turnOnMicrophone),
                accessibilityLabel: "Turn on microphone access",
                accessibilityHint: "Microphone access is off, so Steno can’t dictate until it’s allowed.")
        }
        layout.latestCopy = row(.copyLatest, id: "copy-last")

        // Recording controls and Undo Discard: the model's own rows.
        let controls = [
            row(.discard, id: "discard"),
            row(.undoDiscard, id: "undo-discard"),
        ].compactMap { $0 }
        if !controls.isEmpty { layout.groups.append(controls) }

        // Paste Last, Earlier and Microphone sit together; Copy Last is the card's glyph.
        var sections: [GroveMenuRow] = [row(.pasteLast, id: "paste-last")].compactMap { $0 }
        let recent = items.compactMap { spec -> (MenuBarItemSpec, UUID)? in
            if case .action(.copyEntry(let id)) = spec.kind { (spec, id) } else { nil }
        }
        if !recent.isEmpty {
            let isOpen = expanded.contains(.earlier)
            sections.append(disclosure(.earlier, title: "Earlier", isOpen: isOpen))
            if isOpen {
                sections += recent.map { spec, id in
                    GroveMenuRow(
                        id: "earlier.\(id.uuidString)", title: spec.title, behaviour: .action(.copyEntry(id)),
                        entry: spec.entry, isNested: true,
                        accessibilityLabel: "Copy \(spec.title)", accessibilityHint: spec.entry.map { ClockTime.string($0.createdAt) })
                }
            }
        }
        if let microphone = items.first(where: { $0.title == "Microphone" }), case .submenu(let children) = microphone.kind {
            let isOpen = expanded.contains(.microphone)
            var row = disclosure(.microphone, title: "Microphone", isOpen: isOpen)
            row.detail = Self.currentMicrophoneName(snapshot)
            sections.append(row)
            if isOpen {
                for child in children {
                    guard case .action(let action) = child.kind else { continue }
                    sections.append(GroveMenuRow(
                        id: "microphone." + Self.microphoneID(action), title: child.title, behaviour: .action(action),
                        isEnabled: child.isEnabled, isChecked: child.isChecked, isNested: true,
                        accessibilityLabel: child.title))
                }
            }
        }
        layout.groups.append(sections)

        layout.groups.append([
            row(.openSteno, id: "open-steno"),
            row(.openSettings, id: "settings"),
            row(.quit, id: "quit"),
        ].compactMap { $0 })
        layout.groups.removeAll { $0.isEmpty }
        return layout
    }

    private static func disclosure(_ section: GroveMenuSection, title: String, isOpen: Bool) -> GroveMenuRow {
        GroveMenuRow(
            id: section.rawValue, title: title, behaviour: .disclosure(section), isChecked: isOpen,
            accessibilityLabel: title)
    }

    /// The input the next dictation uses: the chosen device, or the system's own pick.
    static func currentMicrophoneName(_ snapshot: MenuBarSnapshot) -> String? {
        if let id = snapshot.selectedDeviceID, let device = snapshot.devices.first(where: { $0.id == id }) {
            return device.name
        }
        return snapshot.devices.first(where: \.isDefault)?.name
    }

    private static func microphoneID(_ action: MenuBarAction) -> String {
        if case .selectMicrophone(let id) = action { id ?? "system" } else { "other" }
    }
}

// MARK: - Shortcut text

enum GroveMenuShortcut {
    /// "⇧⌘C", "⌃⌥V", "F13": the modifiers in the order macOS prints them, then the key.
    static func text(key: String, modifiers: NSEvent.ModifierFlags) -> String? {
        guard !key.isEmpty else { return nil }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        if let scalar = key.unicodeScalars.first,
           (UInt32(NSF1FunctionKey)...UInt32(NSF35FunctionKey)).contains(scalar.value) {
            return text + "F\(scalar.value - UInt32(NSF1FunctionKey) + 1)"
        }
        return text + key.uppercased()
    }
}

// MARK: - Keys

/// What the panel does with the keyboard.
enum GroveMenuKey: Equatable {
    case up, down, left, right
    case activate
    case escape
    case character(String, NSEvent.ModifierFlags)

    /// The key a key-down event means, or nil for one the panel doesn't use.
    init?(_ event: NSEvent) {
        switch event.keyCode {
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        case 36, 76, 49: self = .activate
        case 53: self = .escape
        default:
            guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }
            self = .character(characters, event.modifierFlags)
        }
    }
}

/// A key typed in another app while the panel is open, by its key code alone.
enum GroveMenuGlobalKey: Equatable {
    case escape, up, down, other

    init(keyCode: UInt16) {
        switch keyCode {
        case 53: self = .escape
        case 126: self = .up
        case 125: self = .down
        default: self = .other
        }
    }
}

// MARK: - State

/// What the Grove panel shows and how it responds, apart from AppKit. The panel and the view
/// are thin shells over this.
@MainActor
final class GroveMenuState: ObservableObject {
    @Published private(set) var snapshot: MenuBarSnapshot
    @Published private(set) var targetAppName: String?
    @Published private(set) var expanded: Set<GroveMenuSection> = []
    @Published private(set) var highlightedID: String?
    /// Carries the input level to the header's bars while recording, without redrawing the panel.
    let haloSource = GroveHaloSource()
    /// True once the keyboard drives the panel; the highlight stays visible while it does.
    @Published private(set) var usesKeyboard = false
    private(set) var layout: GroveMenuLayout

    /// Where each target sits in the panel's own top-left coordinate space, reported by the view.
    var frames: [String: CGRect] = [:]

    /// Runs a menu command. The panel has already closed.
    var perform: (MenuBarAction) -> Void = { _ in }
    /// Closes the panel.
    var close: () -> Void = {}
    /// Asks the panel to fit its content again.
    var contentDidChange: () -> Void = {}

    init(snapshot: MenuBarSnapshot = MenuBarSnapshot(), targetAppName: String? = nil) {
        self.snapshot = snapshot
        self.targetAppName = targetAppName
        layout = GroveMenuLayout.make(snapshot: snapshot, expanded: [])
    }

    func update(snapshot: MenuBarSnapshot, targetAppName: String?) {
        self.snapshot = snapshot
        self.targetAppName = targetAppName
        rebuild()
    }

    /// A fresh opening: sections collapsed and nothing highlighted until the pointer or keyboard says so.
    func reset(snapshot: MenuBarSnapshot, targetAppName: String?, usesKeyboard: Bool) {
        expanded = []
        highlightedID = nil
        frames = [:]
        self.usesKeyboard = usesKeyboard
        self.snapshot = snapshot
        self.targetAppName = targetAppName
        layout = GroveMenuLayout.make(snapshot: snapshot, expanded: expanded)
        if usesKeyboard { highlightedID = enabledNavigable.first?.id }
    }

    private func rebuild() {
        layout = GroveMenuLayout.make(snapshot: snapshot, expanded: expanded)
        if let highlightedID, layout.row(withID: highlightedID) == nil { self.highlightedID = nil }
        contentDidChange()
    }

    // MARK: Navigation

    private var enabledNavigable: [GroveMenuRow] { layout.navigable.filter(\.isEnabled) }

    func moveHighlight(by step: Int) {
        usesKeyboard = true
        let rows = enabledNavigable
        guard !rows.isEmpty else { return }
        guard let current = highlightedID.flatMap({ id in rows.firstIndex { $0.id == id } }) else {
            highlightedID = (step > 0 ? rows.first : rows.last)?.id
            return
        }
        highlightedID = rows[(current + step + rows.count) % rows.count].id
    }

    /// Opens or closes a section. Opening keeps the highlight on its title.
    func toggle(_ section: GroveMenuSection) {
        if expanded.contains(section) { expanded.remove(section) } else { expanded.insert(section) }
        rebuild()
    }

    func setExpanded(_ section: GroveMenuSection, _ isOpen: Bool) {
        guard expanded.contains(section) != isOpen else { return }
        toggle(section)
    }

    // MARK: Running

    func activate(_ row: GroveMenuRow) {
        guard row.isEnabled else { return }
        switch row.behaviour {
        case .disclosure(let section):
            highlightedID = row.id
            toggle(section)
        case .action(let action):
            close()
            perform(action)
        }
    }

    func activateHighlighted() {
        guard let id = highlightedID, let row = layout.row(withID: id) else { return }
        activate(row)
    }

    /// Handles a key. Returns whether the panel used it.
    @discardableResult
    func handle(_ key: GroveMenuKey) -> Bool {
        switch key {
        case .down:
            moveHighlight(by: 1)
        case .up:
            moveHighlight(by: -1)
        case .right:
            guard let row = highlightedRow, case .disclosure(let section) = row.behaviour else { return true }
            setExpanded(section, true)
        case .left:
            guard let row = highlightedRow else { return true }
            if case .disclosure(let section) = row.behaviour {
                setExpanded(section, false)
            } else if let parent = parentSection(of: row) {
                highlightedID = parent.rawValue
                setExpanded(parent, false)
            }
        case .activate:
            activateHighlighted()
        case .escape:
            close()
        case .character(let characters, let modifiers):
            guard let row = row(forKey: characters, modifiers: modifiers) else { return false }
            activate(row)
        }
        return true
    }

    private var highlightedRow: GroveMenuRow? { highlightedID.flatMap { layout.row(withID: $0) } }

    private func parentSection(of row: GroveMenuRow) -> GroveMenuSection? {
        guard row.isNested else { return nil }
        return expanded.first { row.id.hasPrefix($0.rawValue + ".") }
    }

    /// The row a key equivalent runs: the same key and exactly the same modifiers.
    func row(forKey characters: String, modifiers: NSEvent.ModifierFlags) -> GroveMenuRow? {
        let pressed = modifiers.intersection([.command, .shift, .option, .control])
        return layout.navigable.first { row in
            !row.keyEquivalent.isEmpty
                && row.keyEquivalent.lowercased() == characters.lowercased()
                && row.modifiers.intersection([.command, .shift, .option, .control]) == pressed
        }
    }

    // MARK: Pointer

    /// The row under a point in the panel's top-left coordinate space.
    func row(at point: CGPoint) -> GroveMenuRow? {
        layout.targets.first { frames[$0.id]?.contains(point) == true }
    }

    func pointerMoved(to point: CGPoint) {
        let row = row(at: point)
        usesKeyboard = false
        highlightedID = (row?.isNavigable == true && row?.isEnabled == true) ? row?.id : nil
    }

    func pointerLeft() {
        if !usesKeyboard { highlightedID = nil }
    }

    func click(at point: CGPoint) {
        guard let row = row(at: point) else { return }
        activate(row)
    }

    /// The header's title: what Steno is doing, or whether it can dictate.
    var title: String {
        switch snapshot.iconState {
        case .recording: "Listening"
        case .transcribing: "Transcribing"
        case .idle: "Ready"
        case .attention: "Not ready"
        }
    }

    /// Why Steno can't dictate, as the header's spoken status says it.
    static let microphoneOffCause = "Microphone access is off"

    /// The line under the title in the header: how to start with the shortcuts that are on, or
    /// where a recording is going. Nil when Steno can't dictate and the strip under the header
    /// already says why, so the cause is shown once.
    var subtitle: String? {
        switch snapshot.iconState {
        case .recording:
            if let targetAppName, !targetAppName.isEmpty { "Into \(targetAppName)" } else { "On this Mac" }
        case .transcribing: "On this Mac"
        case .attention: layout.attention == nil ? Self.microphoneOffCause : nil
        case .idle:
            switch (snapshot.shortcuts.optionHold, snapshot.shortcuts.handsFreeKey) {
            case (true, _): "Hold ⌥ Option to dictate"
            case (false, .some(let key)): "Press \(key) to dictate"
            case (false, .none): snapshot.shortcuts.needsInputMonitoring ? "Shortcuts need Input Monitoring" : "Shortcuts are off"
            }
        }
    }

    /// Words for the spoken status line: where a recording is going, the header's second line
    /// with keys by their names, or why Steno can't dictate.
    var statusHint: String {
        switch snapshot.iconState {
        case .recording:
            if let targetAppName, !targetAppName.isEmpty { return "into \(targetAppName)" }
            return "On this Mac"
        case .transcribing:
            return "On this Mac"
        case .attention:
            return Self.microphoneOffCause.prefix(1).lowercased() + Self.microphoneOffCause.dropFirst()
        case .idle:
            let plain = (subtitle ?? "").replacingOccurrences(of: "⌥ Option", with: "Option")
            return plain.prefix(1).lowercased() + plain.dropFirst()
        }
    }
}

// MARK: - Placement

enum GroveMenuPlacement {
    /// The gap between the menu bar and the panel.
    static let gap: CGFloat = 6
    /// The least space kept between the panel and a screen edge.
    static let edgeInset: CGFloat = 8

    /// The panel's frame: its left edge under the status item, its top just below the menu bar,
    /// moved in from the screen's edges when needed. `statusItemFrame` and `screenFrame` are in
    /// screen coordinates.
    static func frame(panelSize: CGSize, statusItemFrame: CGRect, screenFrame: CGRect) -> CGRect {
        var x = statusItemFrame.minX
        x = min(x, screenFrame.maxX - edgeInset - panelSize.width)
        x = max(x, screenFrame.minX + edgeInset)
        let top = statusItemFrame.minY - gap
        return CGRect(x: x, y: top - panelSize.height, width: panelSize.width, height: panelSize.height)
    }

    /// The screen that holds the status item, found by where the item is rather than by which
    /// screen is main.
    static func screenFrame(for statusItemFrame: CGRect, among screens: [CGRect]) -> CGRect? {
        let center = CGPoint(x: statusItemFrame.midX, y: statusItemFrame.midY)
        return screens.first { $0.contains(center) } ?? screens.first
    }
}
