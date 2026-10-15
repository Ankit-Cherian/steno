import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// Today's "Ready · <microphone>" line on a live window, across changes to the connected inputs.
/// The line is drawn text that the accessibility tree does not carry, so the window is compared
/// with a window that was opened with the same inputs already connected.
@Suite("Today microphone line transitions", .serialized)
@MainActor
struct TodayMicrophoneLabelTransitionTests {
    private static let builtIn = AudioInputDevice(id: "builtin", name: "MacBook Pro Microphone", isDefault: true)
    private static let usbDefault = AudioInputDevice(id: "usb", name: "USB Desk Mic", isDefault: true)

    private func today(_ connected: @escaping @MainActor () -> [AudioInputDevice]) -> (DictationController, TransitionHost) {
        let controller = makeTestDictationController(hotkey: StatusReportingHotkeyService(), audioInputDevices: connected)
        controller.microphonePermissionStatus = .granted
        let host = TransitionHost(controller: controller) {
            GroveRenderHarness.window(.today, controller: controller) { GroveTodayView() }
        }
        return (controller, host)
    }

    /// The window as it draws when it is opened with `connected` already plugged in.
    private func freshWindow(_ connected: [AudioInputDevice]) async throws -> NSBitmapImageRep {
        let (controller, host) = today { connected }
        defer { host.close(); controller.teardown() }
        #expect(await host.settle(timeout: .seconds(10)) { host.node(identifier: "today.start") != nil })
        return try #require(host.bitmap())
    }

    @Test("The Ready line names the input the next dictation uses as inputs are plugged in, chosen and unplugged")
    func readyLineFollowsInputs() async throws {
        var connected = [Self.builtIn]
        let (controller, host) = today { connected }
        defer { host.close(); controller.teardown() }
        #expect(await host.settle(timeout: .seconds(10)) { host.node(identifier: "today.start") != nil }, "no stage: \(host.names())")
        let atStart = try #require(host.bitmap())

        // A USB microphone is plugged in and macOS makes it the system input.
        let pluggedIn = [AudioInputDevice(id: "builtin", name: "MacBook Pro Microphone", isDefault: false), Self.usbDefault]
        connected = pluggedIn
        controller.microphone.refreshDevices()
        await host.settle()
        let afterPlugIn = try #require(host.bitmap())
        #expect(TransitionHost.difference(atStart, afterPlugIn) > 0, "the line did not change after a plug-in")
        #expect(TransitionHost.difference(afterPlugIn, try await freshWindow(pluggedIn)) < 0.0005,
                "the line after a plug-in differs from a window opened with the same inputs")

        // The built-in microphone is chosen in the pop-up, so it is the one named.
        let builtInChoice = try #require(TodayMicrophone.choices(for: controller).first { $0.id == "builtin" })
        TodayMicrophone.select(builtInChoice, for: controller)
        await host.settle()
        #expect(TransitionHost.difference(atStart, try #require(host.bitmap())) < 0.0005,
                "the chosen built-in microphone is not named again")

        // The chosen microphone is unplugged, so dictation falls back to the system input.
        let afterUnplug = [Self.usbDefault]
        connected = afterUnplug
        controller.microphone.refreshDevices()
        await host.settle()
        #expect(TransitionHost.difference(afterPlugIn, try #require(host.bitmap())) < 0.0005,
                "the line did not name the system input after the chosen microphone was unplugged")
    }
}
