import Foundation
import StenoKit

/// What Settings › Microphone shows and controls: the connected inputs, the
/// saved choice, whether that choice is missing, and the microphone test.
///
/// The test level is not published. Read `testLevel` from a timeline, or set
/// `onTestLevel`, so a 30 Hz level never invalidates SwiftUI views.
@MainActor
final class MicrophoneSettingsModel: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    /// The saved choice; nil follows the system input.
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var isTesting = false
    /// Why the last test could not start, or nil.
    @Published private(set) var testError: String?
    /// The input the most recent dictation recorded from.
    @Published private(set) var lastCaptureSelection: InputDeviceSelection = .systemInput

    /// The latest test level, 0 when no test runs.
    private(set) var testLevel: Float = 0
    var onTestLevel: ((Float) -> Void)?
    /// Called whenever a test ends: stopped, timed out, or ended by a dictation or the input.
    var onTestStopped: (() -> Void)?

    let isPreview: Bool
    private let tester: (any MicrophoneTesting)?
    private let listDevices: @MainActor () -> [AudioInputDevice]
    private let observer: AudioInputDeviceObserver?
    /// Names of inputs seen while Steno runs, so a disconnected choice can
    /// still be named.
    private var knownNames: [String: String] = [:]

    init(
        tester: (any MicrophoneTesting)?,
        listDevices: @escaping @MainActor () -> [AudioInputDevice],
        observesDeviceChanges: Bool,
        isPreview: Bool = false
    ) {
        self.tester = tester
        self.listDevices = listDevices
        self.isPreview = isPreview
        self.observer = observesDeviceChanges ? AudioInputDeviceObserver() : nil
        tester?.onLevel = { [weak self] level in
            self?.receiveTestLevel(level)
        }
        tester?.onStop = { [weak self] in
            self?.testDidStop()
        }
        observer?.onChange = { [weak self] in
            self?.refreshDevices()
        }
        observer?.start()
        refreshDevices()
    }

    static func preview() -> MicrophoneSettingsModel {
        MicrophoneSettingsModel(
            tester: nil,
            listDevices: {
                [
                    AudioInputDevice(id: "preview-built-in", name: "MacBook Pro Microphone", isDefault: true),
                    AudioInputDevice(id: "preview-usb", name: "USB Microphone", isDefault: false),
                ]
            },
            observesDeviceChanges: false,
            isPreview: true
        )
    }

    var followsSystemInput: Bool { selectedDeviceID == nil }

    /// Whether this Mac can run a microphone test. An isolated preview cannot.
    var canTest: Bool { tester != nil }

    var selection: InputDeviceSelection {
        InputDeviceSelection.resolve(preferredID: selectedDeviceID, availableIDs: devices.map(\.id))
    }

    /// The chosen input is not connected; dictation uses the system input.
    var isSelectedDeviceMissing: Bool { selection.isChosenDeviceMissing }

    /// The chosen input's name, when it was seen since Steno started.
    var selectedDeviceName: String? {
        selectedDeviceID.flatMap(name(for:))
    }

    /// The name of input `id`, when it was seen since Steno started.
    func name(for id: String) -> String? {
        devices.first { $0.id == id }?.name ?? knownNames[id]
    }

    /// The input dictation records from now.
    var activeDevice: AudioInputDevice? {
        if let id = selection.deviceID { return devices.first { $0.id == id } }
        return devices.first(where: \.isDefault)
    }

    func refreshDevices() {
        let listed = listDevices()
        for device in listed { knownNames[device.id] = device.name }
        if listed != devices { devices = listed }
    }

    /// Starts a test of `deviceID`, or of the system input when nil. Settings
    /// passes its unsaved choice so the user can try a microphone first.
    func startTest(deviceID: String?) {
        testError = nil
        guard let tester else { return }
        do {
            try tester.start(deviceID: deviceID)
            isTesting = tester.isRunning
        } catch {
            isTesting = false
            testError = error.localizedDescription
        }
    }

    func stopTest() {
        tester?.stop()
    }

    // MARK: Controller

    func savedChoiceChanged(_ deviceID: String?) {
        if selectedDeviceID != deviceID { selectedDeviceID = deviceID }
    }

    /// A dictation started: its capture takes the microphone.
    func dictationStarted(using selection: InputDeviceSelection) {
        stopTest()
        if lastCaptureSelection != selection { lastCaptureSelection = selection }
    }

    func shutdown() {
        stopTest()
        observer?.stop()
    }

    private func receiveTestLevel(_ level: Float) {
        testLevel = level
        onTestLevel?(level)
    }

    private func testDidStop() {
        testLevel = 0
        if isTesting { isTesting = false }
        onTestStopped?()
    }
}
