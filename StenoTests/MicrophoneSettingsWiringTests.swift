import Foundation
import Testing
@testable import Steno
@testable import StenoKit

/// The Settings Microphone page's inputs and test, backed by the controller's microphone.
@Suite("Microphone settings in the window")
@MainActor
struct MicrophoneSettingsWiringTests {
    private static let devices = [
        AudioInputDevice(id: "builtin", name: "MacBook Pro Microphone", isDefault: true),
        AudioInputDevice(id: "usb", name: "USB Desk Mic", isDefault: false),
    ]

    @MainActor
    private final class Tester: MicrophoneTesting {
        var onLevel: ((Float) -> Void)?
        var onStop: (() -> Void)?
        private(set) var isRunning = false
        private(set) var startedWith: [String?] = []
        var refuses = false

        func start(deviceID: String?) throws {
            if refuses { throw MicrophoneTestError.dictationActive }
            startedWith.append(deviceID)
            isRunning = true
        }

        func stop() {
            guard isRunning else { return }
            isRunning = false
            onLevel?(0)
            onStop?()
        }
    }

    private func controller(
        tester: Tester,
        devices: @escaping @MainActor () -> [AudioInputDevice] = { MicrophoneSettingsWiringTests.devices }
    ) -> DictationController {
        makeTestDictationController(
            hotkey: StatusReportingHotkeyService(),
            makeMicrophoneTester: { _ in tester },
            audioInputDevices: devices
        )
    }

    @Test("The page lists the connected inputs and runs a test of the chosen one")
    func listsInputsAndRunsTest() throws {
        let tester = Tester()
        let controller = controller(tester: tester)
        defer { controller.teardown() }
        let model = MicrophoneTestModel()
        #expect(!model.isAvailable)
        #expect(model.devices.isEmpty)

        model.connect(to: controller.microphone)
        model.refreshDevices()
        #expect(model.devices == Self.devices.map(InputDeviceOption.init))
        #expect(model.isAvailable)

        model.start(deviceID: "usb")
        #expect(model.isTesting)
        #expect(tester.startedWith == ["usb"])
        tester.onLevel?(0.5)
        #expect(model.level == 0.5)
        #expect(model.reachedTarget)

        // The tester's own time limit, or a dictation starting, ends the test.
        tester.stop()
        #expect(!model.isTesting)
        #expect(model.level == 0)
    }

    @Test("A test that is refused does not start, and an isolated preview offers none")
    func refusedAndPreview() {
        let tester = Tester()
        tester.refuses = true
        let live = controller(tester: tester)
        defer { live.teardown() }
        let model = MicrophoneTestModel()
        model.connect(to: live.microphone)
        model.start(deviceID: nil)
        #expect(!model.isTesting)
        #expect(tester.startedWith.isEmpty)

        let preview = IsolatedAppPreview.makeController(populated: false)
        defer { preview.teardown() }
        let previewModel = MicrophoneTestModel()
        previewModel.connect(to: preview.microphone)
        #expect(!previewModel.isAvailable)
        previewModel.start(deviceID: nil)
        #expect(!previewModel.isTesting)
    }

    @Test("A newly connected input appears on the page")
    func hotPlug() async {
        var connected = Array(Self.devices.prefix(1))
        let live = controller(tester: Tester(), devices: { connected })
        defer { live.teardown() }
        let model = MicrophoneTestModel()
        model.connect(to: live.microphone)
        #expect(model.devices.map(\.id) == ["builtin"])
        connected = Self.devices
        live.microphone.refreshDevices()
        #expect(await waitForShortcutCondition { model.devices.map(\.id) == ["builtin", "usb"] })
    }
}
