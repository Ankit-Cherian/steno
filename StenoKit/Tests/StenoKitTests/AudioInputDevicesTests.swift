#if os(macOS)
import Foundation
import Testing
@testable import StenoKit

@Suite("Audio input devices")
struct AudioInputDevicesTests {
    @Test("The list marks the system input and sorts by name")
    func listMarksDefault() {
        let list = AudioInputDevices.makeList(
            [
                .init(uid: "usb-1", name: "USB Desk Mic"),
                .init(uid: "builtin", name: "MacBook Pro Microphone"),
                .init(uid: "airpods", name: "AirPods Pro"),
            ],
            defaultUID: "builtin"
        )
        #expect(list.map(\.id) == ["airpods", "builtin", "usb-1"])
        #expect(list.filter(\.isDefault).map(\.id) == ["builtin"])
    }

    @Test("Devices without a UID or a name are left out, and repeated UIDs appear once")
    func listSkipsUnusable() {
        let list = AudioInputDevices.makeList(
            [
                .init(uid: "", name: "No UID"),
                .init(uid: "blank", name: " "),
                .init(uid: "mic", name: "Mic"),
                .init(uid: "mic", name: "Mic again"),
            ],
            defaultUID: nil
        )
        #expect(list == [AudioInputDevice(id: "mic", name: "Mic", isDefault: false)])
    }

    @Test("The system list has unique IDs and at most one default")
    func systemListIsConsistent() {
        let list = AudioInputDevices.list()
        #expect(Set(list.map(\.id)).count == list.count)
        #expect(list.filter(\.isDefault).count <= 1)
    }

    @Test("An unknown UID resolves to no device")
    func unknownUID() {
        #expect(AudioInputDevices.deviceID(forUID: "steno-test-\(UUID().uuidString)") == nil)
    }
}

@Suite("Input device selection")
struct InputDeviceSelectionTests {
    let available = ["builtin", "usb-1"]

    @Test("No saved choice follows the system input")
    func followsSystem() {
        let selection = InputDeviceSelection.resolve(preferredID: nil, availableIDs: available)
        #expect(selection == .systemInput)
        #expect(selection.deviceID == nil)
        #expect(!selection.isChosenDeviceMissing)
    }

    @Test("A connected choice is used")
    func usesChosenDevice() {
        let selection = InputDeviceSelection.resolve(preferredID: "usb-1", availableIDs: available)
        #expect(selection == .device(id: "usb-1"))
        #expect(selection.deviceID == "usb-1")
        #expect(!selection.isChosenDeviceMissing)
    }

    @Test("A choice that is not connected falls back to the system input and says so")
    func fallsBack() {
        let selection = InputDeviceSelection.resolve(preferredID: "gone", availableIDs: available)
        #expect(selection == .missing(id: "gone"))
        #expect(selection.deviceID == nil)
        #expect(selection.isChosenDeviceMissing)
    }

    @Test("An empty saved choice is treated as following the system input")
    func emptyChoice() {
        #expect(InputDeviceSelection.resolve(preferredID: "", availableIDs: available) == .systemInput)
    }
}
#endif
