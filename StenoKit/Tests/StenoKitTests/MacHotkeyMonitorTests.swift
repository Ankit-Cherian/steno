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

@MainActor
@Suite("MacHotkeyMonitor Paste Last Dictation shortcut")
struct MacHotkeyMonitorPasteLastShortcutTests {
    private func pressedActions(
        _ monitor: MacHotkeyMonitor
    ) -> (actions: () -> [String], pastes: () -> Int) {
        var actions: [String] = []
        var pastes = 0
        monitor.onPressToTalkStart = { actions.append("start") }
        monitor.onPressToTalkConfirmed = { actions.append("confirm") }
        monitor.onPressToTalkStop = { actions.append("stop") }
        monitor.onPressToTalkDiscarded = { actions.append("discard") }
        monitor.onPasteLastShortcut = { pastes += 1 }
        return ({ actions }, { pastes })
    }

    @Test("A chord with Option, pressed after Option was held alone, never finishes a dictation")
    func optionChordNeverDictates() async {
        let monitor = MacHotkeyMonitor(currentModifierFlags: { [.option, .command] })
        monitor.globalToggleKeyCode = nil
        let observed = pressedActions(monitor)
        monitor.start()
        defer { monitor.stop() }

        // Option alone long enough to confirm, then Command, then the chord's
        // key, which the event tap swallows before any key monitor sees it.
        let pressedAt = ProcessInfo.processInfo.systemUptime
        monitor.receive(.modifiersChanged([.option]), at: pressedAt)
        try? await Task.sleep(for: .milliseconds(300))
        monitor.receive(.modifiersChanged([.option, .command]), at: pressedAt + 0.3)
        monitor.receivePasteLastShortcut()
        monitor.receive(.modifiersChanged([]), at: pressedAt + 0.5)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(!observed.actions().contains("stop"))
        #expect(observed.actions().last == "discard")
        #expect(observed.pastes() == 1)
    }

    @Test("The paste from a chord after a held Option arrives after the press is discarded")
    func pasteFollowsTheDiscard() async {
        let monitor = MacHotkeyMonitor(currentModifierFlags: { [.option, .command] })
        monitor.globalToggleKeyCode = nil
        var order: [String] = []
        monitor.onPressToTalkStart = { order.append("start") }
        monitor.onPressToTalkConfirmed = { order.append("confirm") }
        monitor.onPressToTalkDiscarded = { order.append("discard") }
        monitor.onPasteLastShortcut = { order.append("paste") }
        monitor.start()
        defer { monitor.stop() }

        let pressedAt = ProcessInfo.processInfo.systemUptime
        monitor.receive(.modifiersChanged([.option]), at: pressedAt)
        try? await Task.sleep(for: .milliseconds(300))
        monitor.receive(.modifiersChanged([.option, .command]), at: pressedAt + 0.3)
        monitor.receivePasteLastShortcut()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(order == ["start", "confirm", "discard", "paste"])
    }

    @Test("A chord with Option pressed with Command first starts nothing")
    func commandFirstStartsNothing() async {
        let monitor = MacHotkeyMonitor(currentModifierFlags: { [] })
        monitor.globalToggleKeyCode = nil
        let observed = pressedActions(monitor)
        monitor.start()
        defer { monitor.stop() }

        let now = ProcessInfo.processInfo.systemUptime
        monitor.receive(.modifiersChanged([.command]), at: now)
        monitor.receive(.modifiersChanged([.command, .option]), at: now + 0.01)
        monitor.receivePasteLastShortcut()
        monitor.receive(.modifiersChanged([]), at: now + 0.2)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(observed.actions().isEmpty)
        #expect(observed.pastes() == 1)
    }

    @Test("A shortcut whose event tap can't be installed reports it")
    func tapFailureIsReported() throws {
        let monitor = MacHotkeyMonitor(makeEventTap: { _ in nil })
        monitor.globalToggleKeyCode = nil
        var statuses: [HotkeyRegistrationStatus] = []
        monitor.onPasteLastShortcutStatusChanged = { statuses.append($0) }
        monitor.start()
        defer { monitor.stop() }

        monitor.pasteLastShortcut = try #require(GlobalShortcut(preferenceValue: "control+option+command+9"))
        monitor.pasteLastShortcut = nil

        #expect(statuses.count == 2)
        if case .unavailable = statuses.first {} else { Issue.record("Expected unavailable, got \(statuses)") }
        #expect(statuses.last == .disabled)
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
    @Test("While Option is held, the live modifier state is re-read once a second")
    func heldOptionIsResampledEverySecond() throws {
        let monitor = MacHotkeyMonitor(currentModifierFlags: { [.option] })
        monitor.globalToggleKeyCode = nil
        monitor.start()
        defer { monitor.stop() }
        #expect(monitor.modifierResyncTimer == nil)

        monitor.receive(.modifiersChanged([.option]), at: ProcessInfo.processInfo.systemUptime)

        let resync = try #require(monitor.modifierResyncTimer)
        #expect(resync.isValid)
        #expect(resync.timeInterval == 1)
    }

    @Test("A missed Option key-up ends the recording at the next modifier check")
    func missedKeyUpEndsRecording() async throws {
        // The live modifier state says nothing is held; the release event was lost.
        // The check runs when the test fires it, so a slow machine cannot reorder it
        // against the confirmation.
        let monitor = MacHotkeyMonitor(
            modifierResyncInterval: 3_600,
            currentModifierFlags: { [] }
        )
        monitor.globalToggleKeyCode = nil
        var actions: [String] = []
        monitor.onPressToTalkStart = { actions.append("start") }
        monitor.onPressToTalkConfirmed = { actions.append("confirm") }
        monitor.onPressToTalkStop = { actions.append("stop") }
        monitor.onPressToTalkDiscarded = { actions.append("discard") }
        monitor.start()
        defer { monitor.stop() }

        monitor.receive(.modifiersChanged([.option]), at: ProcessInfo.processInfo.systemUptime)
        #expect(await eventuallyOnMain { actions == ["start", "confirm"] })

        try #require(monitor.modifierResyncTimer).fire()

        #expect(await eventuallyOnMain { actions.count == 3 })
        #expect(actions == ["start", "confirm", "stop"])
        #expect(monitor.modifierResyncTimer == nil)
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
        #expect(await eventuallyOnMain { confirmedAt != nil })

        #expect(actions == ["start", "confirm"])
        let elapsed = (confirmedAt ?? 0) - pressedAt
        #expect(elapsed >= PressToTalkKeyFilter.defaultConfirmationDelay)
    }
}
#endif
