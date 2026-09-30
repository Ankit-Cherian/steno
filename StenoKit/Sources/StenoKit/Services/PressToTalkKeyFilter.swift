import Foundation

/// Tells an Option press-to-talk hold apart from keyboard shortcuts that use Option.
///
/// Capture must start the instant Option goes down, so the filter never
/// delays `.start`. It decides afterwards: a press confirms as dictation once
/// Option has been held alone for `confirmationDelay`. Until then the caller
/// holds back the listening overlay and media pause. The press is discarded
/// as a shortcut when another modifier is down at press time or appears
/// before confirmation, when a key or click arrives before confirmation,
/// when a key arrives at any point before release, or when Option is released
/// before the delay ends.
public struct PressToTalkKeyFilter: Sendable, Equatable {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let option = Modifiers(rawValue: 1 << 0)
        public static let command = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    public enum Input: Sendable, Equatable {
        /// The modifier keys now held, from a modifier change event.
        case modifiersChanged(Modifiers)
        /// The modifier keys now held, read periodically so a missed key-up
        /// still ends the press. A sample only ever ends a press.
        case modifiersSampled(Modifiers)
        /// A non-modifier key went down.
        case keyDown
        /// A mouse button went down.
        case pointerDown
        /// The confirmation delay for the current press has passed.
        case confirmationDeadline
    }

    public enum Action: Sendable, Equatable {
        /// Start capture now.
        case start
        /// The press is a dictation: show it and allow the media pause.
        case confirm
        /// Finish the dictation normally.
        case stop
        /// The press was a shortcut: throw the recording away.
        case discard
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case pending(pressedAt: TimeInterval)
        case confirmed
        /// Option is still held, but this press is a shortcut.
        case suppressed
    }

    public static let defaultConfirmationDelay: TimeInterval = 0.15

    public let confirmationDelay: TimeInterval
    public private(set) var phase: Phase = .idle

    public init(confirmationDelay: TimeInterval = PressToTalkKeyFilter.defaultConfirmationDelay) {
        self.confirmationDelay = confirmationDelay
    }

    /// When the pending press confirms, if one is pending.
    public var confirmationDeadline: TimeInterval? {
        guard case .pending(let pressedAt) = phase else { return nil }
        return pressedAt + confirmationDelay
    }

    /// - Parameter now: a monotonic timestamp in seconds.
    public mutating func handle(_ input: Input, at now: TimeInterval) -> [Action] {
        var input = input
        if case .modifiersSampled(let modifiers) = input {
            guard phase != .idle, !modifiers.contains(.option) else { return [] }
            input = .modifiersChanged(modifiers)
        }
        switch phase {
        case .idle:
            guard case .modifiersChanged(let modifiers) = input,
                  modifiers.contains(.option)
            else { return [] }
            if Self.isOptionAlone(modifiers) {
                phase = .pending(pressedAt: now)
                return [.start]
            }
            phase = .suppressed
            return []

        case .pending(let pressedAt):
            switch input {
            case .modifiersChanged(let modifiers):
                if !modifiers.contains(.option) {
                    phase = .idle
                    return now >= pressedAt + confirmationDelay ? [.confirm, .stop] : [.discard]
                }
                guard Self.isOptionAlone(modifiers) else {
                    phase = .suppressed
                    return [.discard]
                }
                return []
            case .keyDown, .pointerDown:
                phase = .suppressed
                return [.discard]
            case .confirmationDeadline:
                guard now >= pressedAt + confirmationDelay else { return [] }
                phase = .confirmed
                return [.confirm]
            case .modifiersSampled:
                return []
            }

        case .confirmed:
            switch input {
            case .modifiersChanged(let modifiers):
                guard !modifiers.contains(.option) else { return [] }
                phase = .idle
                return [.stop]
            case .keyDown:
                // Typing while Option is held is a shortcut, even after a pause.
                phase = .suppressed
                return [.discard]
            case .pointerDown, .confirmationDeadline, .modifiersSampled:
                return []
            }

        case .suppressed:
            if case .modifiersChanged(let modifiers) = input, !modifiers.contains(.option) {
                phase = .idle
            }
            return []
        }
    }

    public mutating func reset() {
        phase = .idle
    }

    private static func isOptionAlone(_ modifiers: Modifiers) -> Bool {
        modifiers.contains(.option) && modifiers.isDisjoint(with: [.command, .control, .shift])
    }
}
