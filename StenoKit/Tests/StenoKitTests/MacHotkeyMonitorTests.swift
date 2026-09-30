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

#if os(macOS)
@MainActor
@Suite("MacHotkeyMonitor press-to-talk")
struct MacHotkeyMonitorPressToTalkTests {
    @Test("A missed Option key-up ends the recording within about a second")
    func missedKeyUpEndsRecording() async {
        // The live modifier state says nothing is held; the release event was lost.
        let monitor = MacHotkeyMonitor(currentModifierFlags: { [] })
        monitor.globalToggleKeyCode = nil
        var actions: [String] = []
        var stoppedAt: TimeInterval?
        monitor.onPressToTalkStart = { actions.append("start") }
        monitor.onPressToTalkConfirmed = { actions.append("confirm") }
        monitor.onPressToTalkStop = {
            actions.append("stop")
            stoppedAt = ProcessInfo.processInfo.systemUptime
        }
        monitor.onPressToTalkDiscarded = { actions.append("discard") }
        monitor.start()
        defer { monitor.stop() }

        let pressedAt = ProcessInfo.processInfo.systemUptime
        monitor.receive(.modifiersChanged([.option]), at: pressedAt)
        for _ in 0..<60 where stoppedAt == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }

        #expect(actions == ["start", "confirm", "stop"])
        let elapsed = (stoppedAt ?? .infinity) - pressedAt
        #expect(elapsed < 1.5, "stopped after \(elapsed) s")
    }

    @Test("The monitor confirms a held Option only after the confirmation window")
    func confirmationWaitsForWindow() async {
        let monitor = MacHotkeyMonitor(currentModifierFlags: { [.option] })
        monitor.globalToggleKeyCode = nil
        var actions: [String] = []
        var confirmedAt: TimeInterval?
        monitor.onPressToTalkStart = { actions.append("start") }
        monitor.onPressToTalkConfirmed = {
            actions.append("confirm")
            confirmedAt = ProcessInfo.processInfo.systemUptime
        }
        monitor.start()
        defer { monitor.stop() }

        let pressedAt = ProcessInfo.processInfo.systemUptime
        monitor.receive(.modifiersChanged([.option]), at: pressedAt)
        for _ in 0..<40 where confirmedAt == nil {
            try? await Task.sleep(for: .milliseconds(25))
        }

        #expect(actions == ["start", "confirm"])
        let elapsed = (confirmedAt ?? 0) - pressedAt
        #expect(elapsed >= PressToTalkKeyFilter.defaultConfirmationDelay)
    }
}
#endif
