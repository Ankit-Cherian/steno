import Foundation
import Testing
@testable import StenoKit

@Test("Hotkey gate toggles once for press plus release")
func hotkeyGatePressReleaseTogglesOnce() {
    var gate = HotkeyToggleGate(debounceWindowSeconds: 0.25)
    let t0 = Date(timeIntervalSince1970: 1000)

    #expect(gate.consume(.pressed, now: t0) == false)
    #expect(gate.consume(.released, now: t0.addingTimeInterval(0.01)) == true)
}

@Test("Hotkey gate ignores repeated presses before one release")
func hotkeyGateIgnoresRepeatedPresses() {
    var gate = HotkeyToggleGate(debounceWindowSeconds: 0.25)
    let t0 = Date(timeIntervalSince1970: 1000)

    #expect(gate.consume(.pressed, now: t0) == false)
    #expect(gate.consume(.pressed, now: t0.addingTimeInterval(0.02)) == false)
    #expect(gate.consume(.pressed, now: t0.addingTimeInterval(0.03)) == false)
    #expect(gate.consume(.released, now: t0.addingTimeInterval(0.04)) == true)
}

@Test("Hotkey gate debounces duplicate releases")
func hotkeyGateDebouncesDuplicateReleases() {
    var gate = HotkeyToggleGate(debounceWindowSeconds: 0.25)
    let t0 = Date(timeIntervalSince1970: 1000)

    #expect(gate.consume(.pressed, now: t0) == false)
    #expect(gate.consume(.released, now: t0.addingTimeInterval(0.01)) == true)

    #expect(gate.consume(.pressed, now: t0.addingTimeInterval(0.02)) == false)
    #expect(gate.consume(.released, now: t0.addingTimeInterval(0.10)) == false)

    #expect(gate.consume(.pressed, now: t0.addingTimeInterval(0.40)) == false)
    #expect(gate.consume(.released, now: t0.addingTimeInterval(0.45)) == true)
}

@Test("Hotkey gate ignores release without press")
func hotkeyGateIgnoresReleaseWithoutPress() {
    var gate = HotkeyToggleGate(debounceWindowSeconds: 0.25)
    let t0 = Date(timeIntervalSince1970: 1000)

    #expect(gate.consume(.released, now: t0) == false)
}
