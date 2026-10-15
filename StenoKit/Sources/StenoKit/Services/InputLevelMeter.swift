import Foundation

/// Converts a microphone power reading in decibels full scale to a level from
/// 0 to 1. Readings at or below the noise floor are exactly 0, so a quiet room
/// reads as still; readings at or above `fullScaleDecibels` are exactly 1.
public struct InputLevelMapping: Sendable, Equatable {
    public var noiseFloorDecibels: Float
    public var fullScaleDecibels: Float

    public init(noiseFloorDecibels: Float, fullScaleDecibels: Float) {
        precondition(fullScaleDecibels > noiseFloorDecibels)
        self.noiseFloorDecibels = noiseFloorDecibels
        self.fullScaleDecibels = fullScaleDecibels
    }

    /// Normal speech into a built-in or headset microphone reads about -35 to
    /// -15 dBFS; an empty room reads below -50 dBFS.
    public static let standard = InputLevelMapping(noiseFloorDecibels: -50, fullScaleDecibels: -10)

    public func level(forDecibels decibels: Float) -> Float {
        guard decibels.isFinite else { return decibels == .infinity ? 1 : 0 }
        if decibels <= noiseFloorDecibels { return 0 }
        if decibels >= fullScaleDecibels { return 1 }
        return (decibels - noiseFloorDecibels) / (fullScaleDecibels - noiseFloorDecibels)
    }
}

/// Smooths a level with separate rise and fall time constants, independent of
/// how often it is updated. A level falling to silence settles to exactly 0.
public struct InputLevelSmoother: Sendable {
    public var attack: TimeInterval
    public var release: TimeInterval
    public private(set) var value: Float = 0

    /// Below this, a level falling toward silence is shown as silence.
    static let silenceThreshold: Float = 0.01

    public init(attack: TimeInterval = 0.030, release: TimeInterval = 0.200) {
        self.attack = attack
        self.release = release
    }

    @discardableResult
    public mutating func update(target: Float, elapsed: TimeInterval) -> Float {
        let target = min(max(target, 0), 1)
        guard elapsed > 0 else { return value }
        let timeConstant = target > value ? attack : release
        let coefficient = Float(1 - exp(-elapsed / timeConstant))
        value += (target - value) * coefficient
        if target == 0, value < Self.silenceThreshold {
            value = 0
        }
        return value
    }

    public mutating func reset() {
        value = 0
    }
}

/// Polls a running capture's power reading at 30 Hz, and only while started,
/// and delivers a smoothed level from 0 to 1 on the main thread.
///
/// The meter never opens a microphone: its owner starts it with a reading of
/// a capture that is already recording, and stops it when that capture ends.
/// Stopping delivers a final 0. Consumers should draw the level directly, for
/// example on a layer, rather than storing it in view state.
public final class InputLevelMeter: @unchecked Sendable {
    public static let pollingInterval: TimeInterval = 1.0 / 30

    private let lock = NSLock()
    private var levelHandler: (@Sendable (Float) -> Void)?
    private let mapping: InputLevelMapping
    private let schedulesTimer: Bool

    // Main thread only.
    private var smoother = InputLevelSmoother()
    private var sampler: (@MainActor () -> Float?)?
    private var timer: Timer?
    private var lastTickTime: TimeInterval?
    private var lastDeliveredLevel: Float = 0

    /// Receives each changed level on the main thread, at most 30 times a
    /// second, and a final 0 when the meter stops.
    public var onLevel: (@Sendable (Float) -> Void)? {
        get { lock.withLock { levelHandler } }
        set { lock.withLock { levelHandler = newValue } }
    }

    /// `schedulesTimer` is false only in tests, which call `tick(now:)`.
    public init(mapping: InputLevelMapping = .standard, schedulesTimer: Bool = true) {
        self.mapping = mapping
        self.schedulesTimer = schedulesTimer
    }

    @MainActor
    public var isRunning: Bool { sampler != nil }

    /// Starts polling `sampler`, which returns the current power in dBFS, or
    /// nil when no reading is available. Replaces any earlier sampler.
    @MainActor
    public func start(sampler: @escaping @MainActor () -> Float?) {
        timer?.invalidate()
        timer = nil
        self.sampler = sampler
        smoother.reset()
        lastTickTime = nil
        guard schedulesTimer else { return }
        let timer = Timer(timeInterval: Self.pollingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick(now: ProcessInfo.processInfo.systemUptime)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops polling and delivers 0 at once. Does nothing when not running.
    @MainActor
    public func stop() {
        guard sampler != nil else { return }
        timer?.invalidate()
        timer = nil
        sampler = nil
        smoother.reset()
        lastTickTime = nil
        lastDeliveredLevel = 0
        onLevel?(0)
    }

    @MainActor
    func tick(now: TimeInterval) {
        guard let sampler else { return }
        let elapsed = lastTickTime.map { min(max(now - $0, 0), 0.5) } ?? Self.pollingInterval
        lastTickTime = now
        let target = sampler().map { mapping.level(forDecibels: $0) } ?? 0
        let level = smoother.update(target: target, elapsed: elapsed)
        guard level != lastDeliveredLevel else { return }
        lastDeliveredLevel = level
        onLevel?(level)
    }
}
