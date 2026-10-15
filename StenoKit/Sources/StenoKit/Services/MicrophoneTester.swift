#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation

public enum MicrophoneTestError: Error, Equatable, LocalizedError {
    /// A dictation is recording or finishing; the test waits for it.
    case dictationActive
    /// The input could not be opened.
    case microphoneUnavailable

    public var errorDescription: String? {
        switch self {
        case .dictationActive:
            return "Finish the current dictation, then test the microphone."
        case .microphoneUnavailable:
            return "The microphone couldn’t be opened."
        }
    }
}

/// Shows whether a microphone hears the user, without dictating.
///
/// A test only measures level. It never writes audio to a file, never creates
/// History or Insights data, and never pauses or resumes media. It refuses to
/// start while a dictation is active and stops by itself after a few seconds.
@MainActor
public protocol MicrophoneTesting: AnyObject {
    /// Starts a test of the input with this UID, or of the system input when
    /// nil. Throws `MicrophoneTestError.dictationActive` during a dictation.
    func start(deviceID: String?) throws
    func stop()
    /// Smoothed levels from 0 to 1 while the test runs, and 0 when it stops.
    var onLevel: ((Float) -> Void)? { get set }
    var isRunning: Bool { get }
    /// Called once when a test ends, by `stop()`, the time limit, or the
    /// input going away.
    var onStop: (() -> Void)? { get set }
}

/// An input that reports its power but records nothing.
@MainActor
protocol MicrophoneLevelSource: AnyObject {
    var currentDecibels: Float? { get }
    var isRunning: Bool { get }
    var onEndedByItself: (@MainActor () -> Void)? { get set }
    func start() throws
    func stop()
}

@MainActor
public final class MacMicrophoneTester: MicrophoneTesting {
    public static let maximumDuration: Duration = .seconds(5)

    public var onLevel: ((Float) -> Void)?
    public var onStop: (() -> Void)?
    public private(set) var isRunning = false
    /// The input the current or last test used.
    public private(set) var selection: InputDeviceSelection = .systemInput

    private let isDictationActive: @MainActor () -> Bool
    private let makeSource: @MainActor (AudioDeviceID?) -> any MicrophoneLevelSource
    private let resolveDevice: @MainActor (String) -> AudioDeviceID?
    private let meter: InputLevelMeter
    private let autoStopDelay: Duration
    private let sleep: @MainActor (Duration) async -> Void
    private var source: (any MicrophoneLevelSource)?
    private var autoStopTask: Task<Void, Never>?

    public convenience init(isDictationActive: @escaping @MainActor () -> Bool) {
        self.init(
            isDictationActive: isDictationActive,
            makeSource: { EngineMicrophoneLevelSource(deviceID: $0) },
            resolveDevice: { AudioInputDevices.deviceID(forUID: $0) },
            meter: InputLevelMeter(),
            autoStopDelay: Self.maximumDuration
        )
    }

    init(
        isDictationActive: @escaping @MainActor () -> Bool,
        makeSource: @escaping @MainActor (AudioDeviceID?) -> any MicrophoneLevelSource,
        resolveDevice: @escaping @MainActor (String) -> AudioDeviceID?,
        meter: InputLevelMeter,
        autoStopDelay: Duration,
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.isDictationActive = isDictationActive
        self.makeSource = makeSource
        self.resolveDevice = resolveDevice
        self.meter = meter
        self.autoStopDelay = autoStopDelay
        self.sleep = sleep
        meter.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.onLevel?(level) }
        }
    }

    public func start(deviceID: String?) throws {
        guard !isDictationActive() else { throw MicrophoneTestError.dictationActive }
        end(notify: false)

        var device: AudioDeviceID?
        var selection = InputDeviceSelection.systemInput
        if let deviceID, !deviceID.isEmpty {
            device = resolveDevice(deviceID)
            selection = device == nil ? .missing(id: deviceID) : .device(id: deviceID)
        }
        let source = makeSource(device)
        do {
            try source.start()
        } catch {
            source.stop()
            throw MicrophoneTestError.microphoneUnavailable
        }
        source.onEndedByItself = { [weak self] in self?.stop() }
        self.source = source
        self.selection = selection
        isRunning = true
        meter.start { [weak source] in source?.currentDecibels }

        let delay = autoStopDelay
        let sleep = sleep
        autoStopTask = Task { [weak self, weak source] in
            await sleep(delay)
            guard !Task.isCancelled, let self, let source, self.source === source else { return }
            self.stop()
        }
    }

    public func stop() {
        end(notify: true)
    }

    private func end(notify: Bool) {
        guard isRunning else { return }
        isRunning = false
        autoStopTask?.cancel()
        autoStopTask = nil
        meter.stop()
        source?.onEndedByItself = nil
        source?.stop()
        source = nil
        if notify { onStop?() }
    }
}

/// Measures an input's level through an audio engine tap. It has no file
/// and keeps no audio: each buffer only updates the latest power reading.
@MainActor
final class EngineMicrophoneLevelSource: MicrophoneLevelSource {
    private let input: PinnedAudioInput
    private let power = AudioPowerReading()

    var onEndedByItself: (@MainActor () -> Void)? {
        get { input.onEndedByItself }
        set { input.onEndedByItself = newValue }
    }

    var isRunning: Bool { input.isRunning }
    var currentDecibels: Float? { isRunning ? power.decibels : nil }

    init(deviceID: AudioDeviceID?) {
        input = PinnedAudioInput(deviceID: deviceID)
    }

    func start() throws {
        let format = try input.prepareFormat()
        input.install(tap: Self.makeTap(power: power), format: format)
        try input.start()
    }

    func stop() {
        input.stop()
    }

    private nonisolated static func makeTap(power: AudioPowerReading) -> AVAudioNodeTapBlock {
        { buffer, _ in power.record(buffer) }
    }
}
#endif
