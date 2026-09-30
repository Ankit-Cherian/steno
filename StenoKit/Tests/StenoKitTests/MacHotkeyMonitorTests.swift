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
#endif
