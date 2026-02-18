import Foundation

enum HotkeySignal: Sendable, Equatable {
    case pressed
    case released
}

struct HotkeyToggleGate: Sendable, Equatable {
    private(set) var isArmed = false
    private(set) var lastToggleAt: Date?
    let debounceWindowSeconds: TimeInterval

    init(debounceWindowSeconds: TimeInterval = 0.25) {
        self.debounceWindowSeconds = debounceWindowSeconds
    }

    mutating func consume(_ signal: HotkeySignal, now: Date = Date()) -> Bool {
        switch signal {
        case .pressed:
            isArmed = true
            return false

        case .released:
            guard isArmed else {
                return false
            }
            isArmed = false

            if let lastToggleAt,
               now.timeIntervalSince(lastToggleAt) < debounceWindowSeconds {
                return false
            }

            self.lastToggleAt = now
            return true
        }
    }

    mutating func reset() {
        isArmed = false
        lastToggleAt = nil
    }
}
