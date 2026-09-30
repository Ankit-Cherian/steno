import Foundation
import Testing
@testable import StenoKit

@Suite("Hands-free key filter")
struct HandsFreeKeyFilterTests {
    private let f18: UInt16 = 79
    private let f5: UInt16 = 96

    @Test("The first press toggles and never reaches the frontmost app")
    func firstPressTogglesAndIsSwallowed() {
        var filter = HandsFreeKeyFilter(keyCode: f18)
        let decision = filter.handle(.keyDown(keyCode: f18, isRepeat: false, hasModifiers: false), at: 10)
        #expect(decision == HandsFreeKeyFilter.Decision(swallow: true, toggle: true))
    }

    @Test("Auto-repeat of a held key is swallowed without toggling again")
    func autoRepeatIsSwallowed() {
        var filter = HandsFreeKeyFilter(keyCode: f5)
        _ = filter.handle(.keyDown(keyCode: f5, isRepeat: false, hasModifiers: false), at: 10)
        for offset in 1...20 {
            let decision = filter.handle(
                .keyDown(keyCode: f5, isRepeat: true, hasModifiers: false),
                at: 10.5 + Double(offset) * 0.03
            )
            #expect(decision == HandsFreeKeyFilter.Decision(swallow: true, toggle: false))
        }
    }

    @Test("The key-up that matches a swallowed press is swallowed too")
    func matchingKeyUpIsSwallowed() {
        var filter = HandsFreeKeyFilter(keyCode: f5)
        _ = filter.handle(.keyDown(keyCode: f5, isRepeat: false, hasModifiers: false), at: 10)
        #expect(filter.handle(.keyUp(keyCode: f5), at: 10.1) == HandsFreeKeyFilter.Decision(swallow: true, toggle: false))
        // A later stray key-up has no swallowed press to pair with.
        #expect(filter.handle(.keyUp(keyCode: f5), at: 10.2) == .pass)
    }

    @Test("A second press inside the debounce interval does not toggle")
    func bounceDoesNotToggle() {
        var filter = HandsFreeKeyFilter(keyCode: f18)
        #expect(filter.handle(.keyDown(keyCode: f18, isRepeat: false, hasModifiers: false), at: 10).toggle)
        _ = filter.handle(.keyUp(keyCode: f18), at: 10.03)
        let bounce = filter.handle(.keyDown(keyCode: f18, isRepeat: false, hasModifiers: false), at: 10.08)
        #expect(bounce == HandsFreeKeyFilter.Decision(swallow: true, toggle: false))
        #expect(filter.handle(.keyUp(keyCode: f18), at: 10.1).swallow)

        let deliberate = filter.handle(.keyDown(keyCode: f18, isRepeat: false, hasModifiers: false), at: 11)
        #expect(deliberate == HandsFreeKeyFilter.Decision(swallow: true, toggle: true))
    }

    @Test("Shortcuts that use the key with a modifier, other keys, and a disabled key pass through")
    func unrelatedEventsPassThrough() {
        var filter = HandsFreeKeyFilter(keyCode: f5)
        #expect(filter.handle(.keyDown(keyCode: f5, isRepeat: false, hasModifiers: true), at: 10) == .pass)
        #expect(filter.handle(.keyUp(keyCode: f5), at: 10.1) == .pass)
        #expect(filter.handle(.keyDown(keyCode: 0, isRepeat: false, hasModifiers: false), at: 11) == .pass)
        #expect(filter.handle(.keyUp(keyCode: 0), at: 11.1) == .pass)

        var disabled = HandsFreeKeyFilter(keyCode: nil)
        #expect(disabled.handle(.keyDown(keyCode: f5, isRepeat: false, hasModifiers: false), at: 12) == .pass)
    }
}
