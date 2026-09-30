#if os(macOS)
import Carbon.HIToolbox
import Foundation
import Testing
@testable import StenoKit

@Suite("Hands-free key codes")
struct HandsFreeKeyTests {
    @Test("Every offered function key uses the code the key sends in standard function-key mode")
    func offeredKeysUseStandardFunctionKeyCodes() {
        let expected: [(String, Int)] = [
            ("F1", kVK_F1), ("F2", kVK_F2), ("F3", kVK_F3), ("F4", kVK_F4),
            ("F5", kVK_F5), ("F6", kVK_F6), ("F7", kVK_F7), ("F8", kVK_F8),
            ("F9", kVK_F9), ("F10", kVK_F10), ("F11", kVK_F11), ("F12", kVK_F12),
            ("F13", kVK_F13), ("F14", kVK_F14), ("F15", kVK_F15), ("F16", kVK_F16),
            ("F17", kVK_F17), ("F18", kVK_F18), ("F19", kVK_F19), ("F20", kVK_F20),
        ]
        #expect(HandsFreeKey.functionKeys.map(\.name) == expected.map(\.0))
        #expect(HandsFreeKey.functionKeys.map { Int($0.keyCode) } == expected.map(\.1))
        for (name, code) in expected {
            #expect(HandsFreeKey.displayName(for: UInt16(code)) == name)
        }
    }

    @Test("F3 and F4 fire in standard mode and still fire for settings saved with media-key codes")
    func f3AndF4MatchBothCodes() {
        for saved: UInt16 in [UInt16(kVK_F3), 160] {
            var filter = HandsFreeKeyFilter(keyCode: saved)
            #expect(filter.handle(.keyDown(keyCode: UInt16(kVK_F3), isRepeat: false, hasModifiers: false), at: 10).toggle)
            _ = filter.handle(.keyUp(keyCode: UInt16(kVK_F3)), at: 10.1)
            #expect(filter.handle(.keyDown(keyCode: 160, isRepeat: false, hasModifiers: false), at: 11).toggle)
            #expect(HandsFreeKey.displayName(for: saved) == "F3")
            #expect(HandsFreeKey.pickerKeyCode(for: saved) == UInt16(kVK_F3))
        }
        for saved: UInt16 in [UInt16(kVK_F4), 131] {
            var filter = HandsFreeKeyFilter(keyCode: saved)
            #expect(filter.handle(.keyDown(keyCode: UInt16(kVK_F4), isRepeat: false, hasModifiers: false), at: 10).toggle)
            _ = filter.handle(.keyUp(keyCode: UInt16(kVK_F4)), at: 10.1)
            #expect(filter.handle(.keyDown(keyCode: 131, isRepeat: false, hasModifiers: false), at: 11).toggle)
            #expect(HandsFreeKey.displayName(for: saved) == "F4")
            #expect(HandsFreeKey.pickerKeyCode(for: saved) == UInt16(kVK_F4))
        }
    }

    @Test("Other keys match only their own code")
    func otherKeysMatchOnlyThemselves() {
        var filter = HandsFreeKeyFilter(keyCode: UInt16(kVK_F18))
        #expect(filter.handle(.keyDown(keyCode: 160, isRepeat: false, hasModifiers: false), at: 10) == .pass)
        #expect(filter.handle(.keyDown(keyCode: UInt16(kVK_F3), isRepeat: false, hasModifiers: false), at: 11) == .pass)
        #expect(HandsFreeKey.matchingKeyCodes(for: UInt16(kVK_F18)) == [UInt16(kVK_F18)])
        #expect(HandsFreeKey.pickerKeyCode(for: nil) == nil)
        #expect(HandsFreeKey.pickerKeyCode(for: UInt16(kVK_F18)) == UInt16(kVK_F18))
    }
}
#endif
