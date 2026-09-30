import Foundation

/// Decides what the hands-free key's event tap does with each key event.
///
/// The first key-down toggles hands-free dictation. Auto-repeat and the
/// key-up that pairs with a swallowed key-down are swallowed as well, so the
/// key never reaches the frontmost app. A second press within the debounce
/// interval is swallowed without toggling again.
public struct HandsFreeKeyFilter: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case keyDown(keyCode: UInt16, isRepeat: Bool, hasModifiers: Bool)
        case keyUp(keyCode: UInt16)
    }

    public struct Decision: Sendable, Equatable {
        public var swallow: Bool
        public var toggle: Bool

        public init(swallow: Bool, toggle: Bool) {
            self.swallow = swallow
            self.toggle = toggle
        }

        public static let pass = Decision(swallow: false, toggle: false)
    }

    public static let defaultDebounceInterval: TimeInterval = 0.25

    public var keyCode: UInt16?
    public let debounceInterval: TimeInterval
    private var heldKeyCode: UInt16?
    private var lastToggleAt: TimeInterval?

    public init(
        keyCode: UInt16?,
        debounceInterval: TimeInterval = HandsFreeKeyFilter.defaultDebounceInterval
    ) {
        self.keyCode = keyCode
        self.debounceInterval = debounceInterval
    }

    /// - Parameter now: a monotonic timestamp in seconds.
    public mutating func handle(_ event: Event, at now: TimeInterval) -> Decision {
        switch event {
        case .keyDown(let code, let isRepeat, let hasModifiers):
            guard !hasModifiers, matches(code) else { return .pass }
            if isRepeat {
                return Decision(swallow: true, toggle: false)
            }
            heldKeyCode = code
            if let lastToggleAt, now - lastToggleAt < debounceInterval {
                return Decision(swallow: true, toggle: false)
            }
            lastToggleAt = now
            return Decision(swallow: true, toggle: true)

        case .keyUp(let code):
            guard let heldKeyCode, heldKeyCode == code else { return .pass }
            self.heldKeyCode = nil
            return Decision(swallow: true, toggle: false)
        }
    }

    private func matches(_ code: UInt16) -> Bool {
        guard let keyCode else { return false }
        return code == keyCode
    }
}
