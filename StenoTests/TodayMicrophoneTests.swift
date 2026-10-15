import Foundation
import Testing
@testable import Steno
@testable import StenoKit

/// Today's microphone pop-up and the recording plate's level, driven through the controller.
@Suite("Microphone on Today")
@MainActor
struct TodayMicrophoneTests {
    private static let devices = [
        AudioInputDevice(id: "builtin", name: "MacBook Pro Microphone", isDefault: true),
        AudioInputDevice(id: "usb", name: "USB Desk Mic", isDefault: false),
    ]

    @Test("The pop-up names the input in use, lists the system input and every connected input, and saves the choice")
    func choiceIsListedAndSaved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoTodayMic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppPreferencesStore(storageURL: directory.appendingPathComponent("preferences.json"))
        let controller = makeTestDictationController(
            hotkey: StatusReportingHotkeyService(),
            preferencesStore: store,
            audioInputDevices: { Self.devices }
        )
        defer { controller.teardown() }

        #expect(TodayMicrophone.current(for: controller)?.name == "MacBook Pro Microphone")
        #expect(TodayMicrophone.choices(for: controller).map(\.name)
            == ["System input", "MacBook Pro Microphone", "USB Desk Mic"])

        let usb = try #require(TodayMicrophone.choices(for: controller).first { $0.id == "usb" })
        TodayMicrophone.select(usb, for: controller)
        #expect(controller.preferences.recording.inputDeviceID == "usb")
        #expect(TodayMicrophone.current(for: controller)?.name == "USB Desk Mic")
        #expect(await waitForShortcutCondition { await store.load().recording.inputDeviceID == "usb" })

        let system = try #require(TodayMicrophone.choices(for: controller).first { $0.id == nil })
        TodayMicrophone.select(system, for: controller)
        #expect(controller.preferences.recording.inputDeviceID == nil)
        #expect(TodayMicrophone.current(for: controller)?.name == "MacBook Pro Microphone")
    }

    @Test("With no input listed, the pop-up is hidden")
    func noInputs() {
        let controller = makeTestDictationController(
            hotkey: StatusReportingHotkeyService(),
            audioInputDevices: { [] }
        )
        defer { controller.teardown() }
        #expect(TodayMicrophone.current(for: controller) == nil)
        #expect(TodayMicrophone.choices(for: controller).isEmpty)
    }

    @Test("The recording plate gets the same levels as the overlay, only while recording, and zero when it ends")
    func plateGetsTheMeterLevel() async {
        let meter = InputLevelMeter(schedulesTimer: false)
        let controller = makeTestDictationController(
            hotkey: StatusReportingHotkeyService(),
            overlay: makeShortcutTestPresenter(),
            coordinator: CaptureTestCoordinator(
                result: InsertResult(status: .inserted, method: .accessibility, insertedText: "Words")
            ),
            inputLevelMeter: meter
        )
        defer { controller.teardown() }
        var received: [Float] = []
        let token = controller.inputLevels.add { received.append($0) }
        meter.start { -15 }

        meter.tick(now: 1)
        #expect(received.isEmpty)

        controller.toggleHandsFree()
        #expect(await waitForShortcutCondition { controller.isRecording })
        meter.tick(now: 2)
        #expect(received.last.map { $0 > 0 } == true)

        controller.stopRecording()
        #expect(received.last == 0)
        let count = received.count
        meter.tick(now: 3)
        #expect(received.count == count)

        controller.inputLevels.remove(token)
        #expect(await waitForShortcutCondition { controller.recordingLifecycleState == .idle })
    }
}
