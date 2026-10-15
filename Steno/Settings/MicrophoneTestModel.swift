import Combine
import Foundation

/// Runs the Microphone page's isolated test. The level is kept outside `@Published` state and read
/// by the level bar on its own schedule, so a running test redraws only the bar.
@MainActor
final class MicrophoneTestModel: ObservableObject {
    /// The share of full scale where a normal speaking voice should land.
    static let targetBand: ClosedRange<Float> = 0.40...0.70
    /// How long a test runs before it stops by itself. Tests that are not about
    /// this limit lengthen it, so a slow machine cannot end their test early.
    static var duration: Duration = .seconds(5)

    @Published private(set) var isTesting = false
    @Published private(set) var devices: [InputDeviceOption] = []
    /// Whether the level reached the target band during the current or last test.
    @Published private(set) var reachedTarget = false
    /// Why the last test could not start, until the next one does.
    @Published private(set) var failure: String?

    /// The latest level, 0...1. Read by `TimelineView`; never published.
    private(set) var level: Float = 0

    private var makeTest: () -> MicrophoneTestRunning?
    private var listDevices: () -> [InputDeviceOption]
    private var test: MicrophoneTestRunning?
    private var stopTask: Task<Void, Never>?
    private var deviceObservation: AnyCancellable?

    /// A model with nothing behind it until `connect(to:)`: no inputs, and no test can run.
    init(
        makeTest: @escaping () -> MicrophoneTestRunning? = { nil },
        listDevices: @escaping () -> [InputDeviceOption] = { [] }
    ) {
        self.makeTest = makeTest
        self.listDevices = listDevices
    }

    /// Takes the inputs and the test from the controller's microphone model. Safe to call again.
    func connect(to microphone: MicrophoneSettingsModel) {
        guard connectedModel !== microphone else { return }
        stop()
        connectedModel = microphone
        test = nil
        listDevices = { microphone.devices.map(InputDeviceOption.init) }
        makeTest = { microphone.canTest ? ControllerMicrophoneTest(microphone: microphone) : nil }
        devices = listDevices()
        deviceObservation = microphone.$devices
            .map { $0.map(InputDeviceOption.init) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.devices = $0 }
    }

    private var connectedModel: MicrophoneSettingsModel?

    /// The name of input `id`: listed now, or seen earlier while Steno ran.
    func name(for id: String) -> String? {
        devices.first { $0.id == id }?.name ?? connectedModel?.name(for: id)
    }

    #if DEBUG
    /// A fixed state for render tests.
    static func preview(devices: [InputDeviceOption], testingAt level: Float?) -> MicrophoneTestModel {
        let model = MicrophoneTestModel(makeTest: { nil }, listDevices: { devices })
        model.devices = devices
        model.previewAvailable = true
        if let level {
            model.isTesting = true
            model.level = level
            model.reachedTarget = Self.targetBand.contains(level)
        }
        return model
    }
    #endif

    /// Whether a test can run on this Mac at all.
    var isAvailable: Bool { previewAvailable || resolvedTest() != nil }
    private var previewAvailable = false

    private func resolvedTest() -> MicrophoneTestRunning? {
        if test == nil { test = makeTest() }
        return test
    }

    func refreshDevices() {
        connectedModel?.refreshDevices()
        devices = listDevices()
    }

    func toggle(deviceID: String?) {
        isTesting ? stop() : start(deviceID: deviceID)
    }

    func start(deviceID: String?) {
        guard !isTesting, let test = resolvedTest() else { return }
        level = 0
        reachedTarget = false
        test.onLevel = { [weak self] level in
            guard let self else { return }
            self.level = level
            if Self.targetBand.contains(level), !self.reachedTarget {
                self.reachedTarget = true
            }
        }
        test.onStop = { [weak self] in
            self?.testEnded()
        }
        do {
            try test.start(deviceID: deviceID)
        } catch {
            test.onLevel = nil
            test.onStop = nil
            failure = error.localizedDescription
            return
        }
        failure = nil
        isTesting = true
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        test?.stop()
        testEnded()
    }

    /// The test ended: by `stop()`, after 5 seconds, because a dictation started, or because the
    /// input went away.
    private func testEnded() {
        stopTask?.cancel()
        stopTask = nil
        if isTesting { isTesting = false }
        level = 0
    }
}
