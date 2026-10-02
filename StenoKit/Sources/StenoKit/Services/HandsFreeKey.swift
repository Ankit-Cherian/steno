import Foundation

/// Virtual key codes for the function keys offered as the hands-free key.
public enum HandsFreeKey {
    public struct FunctionKey: Sendable, Equatable {
        public let name: String
        public let keyCode: UInt16
    }

    /// F1 to F20, with the codes each key sends in standard function-key mode.
    public static let functionKeys: [FunctionKey] = [
        FunctionKey(name: "F1", keyCode: 122),
        FunctionKey(name: "F2", keyCode: 120),
        FunctionKey(name: "F3", keyCode: 99),
        FunctionKey(name: "F4", keyCode: 118),
        FunctionKey(name: "F5", keyCode: 96),
        FunctionKey(name: "F6", keyCode: 97),
        FunctionKey(name: "F7", keyCode: 98),
        FunctionKey(name: "F8", keyCode: 100),
        FunctionKey(name: "F9", keyCode: 101),
        FunctionKey(name: "F10", keyCode: 109),
        FunctionKey(name: "F11", keyCode: 103),
        FunctionKey(name: "F12", keyCode: 111),
        FunctionKey(name: "F13", keyCode: 105),
        FunctionKey(name: "F14", keyCode: 107),
        FunctionKey(name: "F15", keyCode: 113),
        FunctionKey(name: "F16", keyCode: 106),
        FunctionKey(name: "F17", keyCode: 64),
        FunctionKey(name: "F18", keyCode: 79),
        FunctionKey(name: "F19", keyCode: 80),
        FunctionKey(name: "F20", keyCode: 90),
    ]

    private static let f3: UInt16 = 99
    private static let f4: UInt16 = 118
    /// Earlier versions saved F3 and F4 as the codes Apple keyboards send
    /// for Mission Control and Launchpad in media-key mode.
    private static let mediaModeF3: UInt16 = 160
    private static let mediaModeF4: UInt16 = 131

    /// The codes that trigger a saved hands-free key. F3 and F4 accept both
    /// their standard code and their media-key code, so the key fires in
    /// either keyboard mode and settings saved by earlier versions keep working.
    public static func matchingKeyCodes(for savedKeyCode: UInt16) -> Set<UInt16> {
        switch savedKeyCode {
        case f3, mediaModeF3: return [f3, mediaModeF3]
        case f4, mediaModeF4: return [f4, mediaModeF4]
        default: return [savedKeyCode]
        }
    }

    /// The Settings picker entry for a saved key code.
    public static func pickerKeyCode(for savedKeyCode: UInt16?) -> UInt16? {
        switch savedKeyCode {
        case mediaModeF3: return f3
        case mediaModeF4: return f4
        default: return savedKeyCode
        }
    }

    public static func displayName(for keyCode: UInt16) -> String? {
        guard let pickerKeyCode = pickerKeyCode(for: keyCode) else { return nil }
        return functionKeys.first { $0.keyCode == pickerKeyCode }?.name
    }
}
