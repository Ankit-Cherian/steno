import Foundation

/// A key combination that runs a Steno action from any app, such as Paste
/// Last Dictation. Saved as text: the modifier names, then the virtual key
/// code, joined by "+" (for example "control+option+command+9").
public struct GlobalShortcut: Sendable, Hashable {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// Why a combination can't be a shortcut.
    public enum Problem: Sendable, Equatable {
        /// The key is itself a modifier, such as the press-to-talk Option key.
        case modifierKey
        /// A key other than a function key needs Command, Control or Option.
        case needsModifier
        /// Option without Command or Control types a character, and holding
        /// Option starts press-to-talk.
        case optionNeedsCommandOrControl
        /// macOS or most apps already use it.
        case reserved
    }

    public let keyCode: UInt16
    public let modifiers: Modifiers

    /// Returns nil for a combination with a `Problem`.
    public init?(keyCode: UInt16, modifiers: Modifiers) {
        guard Self.problem(keyCode: keyCode, modifiers: modifiers) == nil else { return nil }
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Nil, empty, unreadable or refused text means no shortcut.
    public init?(preferenceValue: String?) {
        guard let (keyCode, modifiers) = Self.parse(preferenceValue) else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    public static func problem(keyCode: UInt16, modifiers: Modifiers) -> Problem? {
        if modifierKeyCodes.contains(keyCode) { return .modifierKey }
        if modifiers.contains(.option), modifiers.isDisjoint(with: [.command, .control]) {
            return .optionNeedsCommandOrControl
        }
        let isFunctionKey = HandsFreeKey.functionKeys.contains { $0.keyCode == keyCode }
        if !isFunctionKey, modifiers.isDisjoint(with: [.command, .control, .option]) {
            return .needsModifier
        }
        if reservedChords.contains(Chord(keyCode: keyCode, modifiers: modifiers)) { return .reserved }
        return nil
    }

    /// The problem with readable saved text, or nil when it is usable or unreadable.
    public static func problem(withPreferenceValue value: String?) -> Problem? {
        guard let (keyCode, modifiers) = parse(value) else { return nil }
        return problem(keyCode: keyCode, modifiers: modifiers)
    }

    /// True when the shortcut uses the hands-free key, with any modifiers,
    /// so one key never has two meanings.
    public func collides(withHandsFreeKeyCode handsFreeKeyCode: UInt16?) -> Bool {
        guard let handsFreeKeyCode else { return false }
        return HandsFreeKey.matchingKeyCodes(for: handsFreeKeyCode).contains(keyCode)
    }

    private static func parse(_ value: String?) -> (UInt16, Modifiers)? {
        guard let parts = value?.lowercased().split(separator: "+").map(String.init),
              let last = parts.last,
              let keyCode = UInt16(last) else { return nil }
        var modifiers: Modifiers = []
        for name in parts.dropLast() {
            guard let modifier = modifierNames.first(where: { $0.name == name })?.modifier else {
                return nil
            }
            modifiers.insert(modifier)
        }
        return (keyCode, modifiers)
    }

    private struct Chord: Hashable {
        let keyCode: UInt16
        let modifiers: Modifiers
    }

    /// Command, Shift, Caps Lock, Option, Control (each side), Fn and Globe.
    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 179]

    /// Editing, window, app and input chords that people press without
    /// thinking, so taking them over would surprise.
    private static let reservedChords: Set<Chord> = {
        let command: [UInt16] = [0, 1, 3, 4, 6, 7, 8, 9, 12, 13, 17, 31, 35, 43, 45, 46, 48, 49, 50]
        var chords = Set(command.map { Chord(keyCode: $0, modifiers: [.command]) })
        for key: UInt16 in [6, 9, 20, 21, 23] { chords.insert(Chord(keyCode: key, modifiers: [.command, .shift])) }
        for key: UInt16 in [2, 4, 53, 49] { chords.insert(Chord(keyCode: key, modifiers: [.command, .option])) }
        for key: UInt16 in [3, 12, 49] { chords.insert(Chord(keyCode: key, modifiers: [.command, .control])) }
        chords.insert(Chord(keyCode: 49, modifiers: [.control]))
        chords.insert(Chord(keyCode: 49, modifiers: [.control, .option]))
        return chords
    }()

    /// The lowercase letter this shortcut's key types on an ANSI layout, or nil for any other key.
    public var letter: Character? {
        Self.letterKeys[keyCode]?.lowercased().first
    }

    public var preferenceValue: String {
        (Self.modifierNames.filter { modifiers.contains($0.modifier) }.map(\.name) + [String(keyCode)])
            .joined(separator: "+")
    }

    /// The combination as macOS menus show it, for example "⌃⌥⌘V".
    public var displayName: String {
        let symbols = Self.modifierNames.filter { modifiers.contains($0.modifier) }.map(\.symbol).joined()
        let key = HandsFreeKey.displayName(for: keyCode) ?? Self.letterKeys[keyCode] ?? "Key \(keyCode)"
        return symbols + key
    }

    private static let modifierNames: [(name: String, symbol: String, modifier: Modifiers)] = [
        ("control", "⌃", .control), ("option", "⌥", .option), ("shift", "⇧", .shift), ("command", "⌘", .command),
    ]

    /// ANSI letter positions, which every Mac layout reports by key code.
    private static let letterKeys: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K",
        37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U",
        9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
    ]
}

/// Decides what the event tap does with each key event for one shortcut.
///
/// The shortcut fires once per press and its key never reaches the
/// frontmost app: auto-repeat and the paired key-up are swallowed too. Any
/// other modifier combination passes through untouched.
public struct GlobalShortcutFilter: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case keyDown(keyCode: UInt16, modifiers: GlobalShortcut.Modifiers, isRepeat: Bool)
        case keyUp(keyCode: UInt16)
    }

    public struct Decision: Sendable, Equatable {
        public var swallow: Bool
        public var fire: Bool

        public static let pass = Decision(swallow: false, fire: false)
    }

    public var shortcut: GlobalShortcut? {
        didSet { if shortcut != oldValue { heldKeyCode = nil } }
    }
    private var heldKeyCode: UInt16?

    public init(shortcut: GlobalShortcut?) {
        self.shortcut = shortcut
    }

    public mutating func handle(_ event: Event) -> Decision {
        switch event {
        case .keyDown(let keyCode, let modifiers, let isRepeat):
            guard let shortcut else { return .pass }
            // The press already fired and was swallowed, so its repeats stay swallowed
            // even once the modifiers are lifted or changed; otherwise the bare key
            // would type into the frontmost app while the key is still held.
            if isRepeat, heldKeyCode == keyCode {
                return Decision(swallow: true, fire: false)
            }
            guard shortcut.keyCode == keyCode, shortcut.modifiers == modifiers else {
                return .pass
            }
            if isRepeat {
                return Decision(swallow: true, fire: false)
            }
            heldKeyCode = keyCode
            return Decision(swallow: true, fire: true)
        case .keyUp(let keyCode):
            guard heldKeyCode == keyCode else { return .pass }
            heldKeyCode = nil
            return Decision(swallow: true, fire: false)
        }
    }
}
