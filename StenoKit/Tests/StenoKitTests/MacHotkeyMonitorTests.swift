#if os(macOS)
import Foundation
import Testing
@testable import StenoKit

@MainActor
@Suite("MacHotkeyMonitor registration status")
struct MacHotkeyMonitorRegistrationStatusTests {
    @Test("A disabled hands-free key reports its own status once, not a failure on every assignment")
    func disabledKeyReportsDisabledOnce() {
        let monitor = MacHotkeyMonitor()
        var events: [HotkeyRegistrationStatus] = []
        monitor.onRegistrationStatusChanged = { events.append($0) }
        monitor.globalToggleKeyCode = nil
        #expect(events.isEmpty)

        // Launch, every Save, and every runtime rebuild reassign the same value.
        monitor.start()
        monitor.globalToggleKeyCode = nil
        monitor.globalToggleKeyCode = nil

        // Permission refreshes restart the monitor and reassign the key.
        monitor.stop()
        monitor.start()
        monitor.globalToggleKeyCode = nil

        #expect(events == [.disabled])
        monitor.stop()
    }
}

@Suite("Event tap re-enable policy")
struct EventTapReenablePolicyTests {
    @Test("A tap disabled long after the last re-enable is re-enabled at once")
    func reenablesImmediatelyAfterQuietPeriod() {
        #expect(EventTapReenablePolicy.delay(now: 100, lastReenable: 0) == 0)
        #expect(EventTapReenablePolicy.delay(now: 100.2, lastReenable: 100) == 0)
    }

    @Test("A tap disabled again inside the debounce interval is re-enabled after a short delay, never left off")
    func reenablesLaterInsideDebounceInterval() {
        let delay = EventTapReenablePolicy.delay(now: 100.03, lastReenable: 100)
        #expect(delay > 0)
        #expect(delay <= EventTapReenablePolicy.minimumInterval)
        #expect(abs(delay - 0.07) < 0.000_1)
    }
}
#endif
