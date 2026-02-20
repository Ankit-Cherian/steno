#if os(macOS)
import AppKit
import IOKit.hidsystem

@MainActor
public final class MacMediaInterruptionService: MediaInterruptionService {
    private static let logger = StenoKitDiagnostics.logger
    private var activeTokens: Set<UUID> = []
    private let playbackDetector: any MediaPlaybackStateDetector
    private let sendPlayPauseKey: () -> Bool

    public init() {
        let bridge = MediaRemoteBridge()
        self.playbackDetector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
        self.sendPlayPauseKey = SystemMediaKeySender.sendPlayPause
    }

    init(
        playbackDetector: any MediaPlaybackStateDetector,
        sendPlayPauseKey: @escaping () -> Bool
    ) {
        self.playbackDetector = playbackDetector
        self.sendPlayPauseKey = sendPlayPauseKey
    }

    public func beginInterruption() async -> MediaInterruptionToken? {
        if Task.isCancelled {
            Self.logger.debug("Skipping media interruption because task is cancelled before detection.")
            return nil
        }

        let detection = await playbackDetector.detect()
        if Task.isCancelled {
            Self.logger.debug("Skipping media interruption because task is cancelled after detection.")
            return nil
        }

        switch detection {
        case .playing, .likelyPlaying:
            if Task.isCancelled {
                Self.logger.debug("Skipping media interruption because task is cancelled before key send.")
                return nil
            }
            let didSend = sendPlayPauseKey()
            Self.logger.debug("Media interruption pause key send attempted: \(didSend, privacy: .public)")
            guard didSend else { return nil }
            let token = MediaInterruptionToken()
            activeTokens.insert(token.id)
            Self.logger.debug("Media interruption started. Active tokens: \(self.activeTokens.count, privacy: .public)")
            return token
        case .notPlaying, .unknown:
            Self.logger.debug("Media interruption skipped. Detection: \(detection.logValue, privacy: .public)")
            return nil
        }
    }

    public func endInterruption(token: MediaInterruptionToken) {
        guard activeTokens.contains(token.id) else {
            Self.logger.debug("Ignoring endInterruption for unknown token.")
            return
        }
        activeTokens.remove(token.id)
        let didSend = sendPlayPauseKey()
        Self.logger.debug("Media interruption resume key send attempted: \(didSend, privacy: .public)")
        Self.logger.debug("Media interruption ended. Active tokens: \(self.activeTokens.count, privacy: .public)")
    }
}

enum PlaybackDetectionResult: Sendable, Equatable {
    case playing
    case likelyPlaying
    case notPlaying
    case unknown

    var logValue: String {
        switch self {
        case .playing:
            "playing"
        case .likelyPlaying:
            "likelyPlaying"
        case .notPlaying:
            "notPlaying"
        case .unknown:
            "unknown"
        }
    }
}

@MainActor
protocol MediaPlaybackStateDetector {
    func detect() async -> PlaybackDetectionResult
}

@MainActor
protocol MediaRemoteBridging: Sendable {
    func activate()
    func deactivate()
    func anyApplicationIsPlaying() async -> Bool?
    func nowPlayingApplicationIsPlaying() async -> Bool?
    func nowPlayingPlaybackState() async -> Int?
    func nowPlayingPlaybackRate() async -> Double?
    func isPlaybackStateAdvancing(_ playbackState: Int) -> Bool?
}

final class MultiSignalMediaPlaybackStateDetector: MediaPlaybackStateDetector {
    private static let logger = StenoKitDiagnostics.logger
    private let bridge: any MediaRemoteBridging

    init(bridge: any MediaRemoteBridging = MediaRemoteBridge()) {
        self.bridge = bridge
    }

    func detect() async -> PlaybackDetectionResult {
        bridge.activate()
        defer { bridge.deactivate() }

        async let anyApplicationIsPlaying = bridge.anyApplicationIsPlaying()
        async let nowPlayingApplicationIsPlaying = bridge.nowPlayingApplicationIsPlaying()
        async let nowPlayingPlaybackState = bridge.nowPlayingPlaybackState()
        async let nowPlayingPlaybackRate = bridge.nowPlayingPlaybackRate()

        let anyPlaying = await anyApplicationIsPlaying
        let nowPlaying = await nowPlayingApplicationIsPlaying
        let playbackState = await nowPlayingPlaybackState
        let playbackRate = await nowPlayingPlaybackRate
        let playbackStateIsAdvancing = playbackState.flatMap { bridge.isPlaybackStateAdvancing($0) }

        let hasStrongPositive =
            (playbackRate.map { $0 > 0 } ?? false)
            || (playbackStateIsAdvancing == true)

        let hasStrongNegative =
            (playbackRate.map { $0 == 0 } ?? false)
            || (playbackStateIsAdvancing == false)

        let hasWeakPositive = (anyPlaying == true) || (nowPlaying == true)

        let result: PlaybackDetectionResult
        if hasStrongPositive && !hasStrongNegative {
            result = .playing
        } else if hasStrongPositive && hasStrongNegative {
            result = .unknown
        } else if hasStrongNegative {
            result = .notPlaying
        } else if hasWeakPositive {
            result = .likelyPlaying
        } else {
            result = .unknown
        }

        Self.logger.debug(
            """
            Media detection probes any=\(Self.describe(anyPlaying), privacy: .public) \
            nowPlaying=\(Self.describe(nowPlaying), privacy: .public) \
            state=\(Self.describe(playbackState), privacy: .public) \
            stateAdvancing=\(Self.describe(playbackStateIsAdvancing), privacy: .public) \
            rate=\(Self.describe(playbackRate), privacy: .public) \
            result=\(result.logValue, privacy: .public)
            """
        )
        return result
    }

    private static func describe(_ value: Bool?) -> String {
        value.map { String($0) } ?? "nil"
    }

    private static func describe(_ value: Int?) -> String {
        value.map { String($0) } ?? "nil"
    }

    private static func describe(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.4f", value)
    }
}

@MainActor
final class MediaRemoteBridge: MediaRemoteBridging {
    private typealias SetWantsNowPlayingNotificationsFn = @convention(c) (Bool) -> Void
    private typealias RegisterForNowPlayingNotificationsFn = @convention(c) (DispatchQueue) -> Void
    private typealias UnregisterForNowPlayingNotificationsFn = @convention(c) () -> Void
    private typealias BoolProbeFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias PlaybackStateProbeFn = @convention(c) (DispatchQueue, @escaping (Int) -> Void) -> Void
    private typealias PlaybackStateIsAdvancingFn = @convention(c) (Int) -> Bool
    private typealias NowPlayingInfoProbeFn = @convention(c) (DispatchQueue, @escaping ([AnyHashable: Any]?) -> Void) -> Void
    private static let logger = StenoKitDiagnostics.logger

    private nonisolated(unsafe) let handle: UnsafeMutableRawPointer?
    private let callbackQueue: DispatchQueue
    private let probeRunner: MediaRemoteAsyncProbeRunner

    private let setWantsNowPlayingNotifications: SetWantsNowPlayingNotificationsFn?
    private let registerForNowPlayingNotifications: RegisterForNowPlayingNotificationsFn?
    private let unregisterForNowPlayingNotifications: UnregisterForNowPlayingNotificationsFn?
    private let getAnyApplicationIsPlaying: BoolProbeFn?
    private let getNowPlayingApplicationIsPlaying: BoolProbeFn?
    private let getNowPlayingApplicationPlaybackState: PlaybackStateProbeFn?
    private let playbackStateIsAdvancingFn: PlaybackStateIsAdvancingFn?
    private let getNowPlayingInfo: NowPlayingInfoProbeFn?
    private let playbackRateInfoKey: String?

    init(
        frameworkPath: String = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
        callbackQueue: DispatchQueue = DispatchQueue(label: "Steno.MediaRemote.Callback", qos: .userInitiated),
        probeRunner: MediaRemoteAsyncProbeRunner = MediaRemoteAsyncProbeRunner()
    ) {
        self.callbackQueue = callbackQueue
        self.probeRunner = probeRunner

        let handle = dlopen(frameworkPath, RTLD_LAZY)
        self.handle = handle

        self.setWantsNowPlayingNotifications = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteSetWantsNowPlayingNotifications",
            as: SetWantsNowPlayingNotificationsFn.self
        )
        self.registerForNowPlayingNotifications = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteRegisterForNowPlayingNotifications",
            as: RegisterForNowPlayingNotificationsFn.self
        )
        self.unregisterForNowPlayingNotifications = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteUnregisterForNowPlayingNotifications",
            as: UnregisterForNowPlayingNotificationsFn.self
        )
        self.getAnyApplicationIsPlaying = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteGetAnyApplicationIsPlaying",
            as: BoolProbeFn.self
        )
        self.getNowPlayingApplicationIsPlaying = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteGetNowPlayingApplicationIsPlaying",
            as: BoolProbeFn.self
        )
        self.getNowPlayingApplicationPlaybackState = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteGetNowPlayingApplicationPlaybackState",
            as: PlaybackStateProbeFn.self
        )
        self.playbackStateIsAdvancingFn = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemotePlaybackStateIsAdvancing",
            as: PlaybackStateIsAdvancingFn.self
        )
        self.getNowPlayingInfo = Self.loadSymbol(
            handle: handle,
            named: "MRMediaRemoteGetNowPlayingInfo",
            as: NowPlayingInfoProbeFn.self
        )
        self.playbackRateInfoKey = Self.loadCFStringConstant(
            handle: handle,
            named: "kMRMediaRemoteNowPlayingInfoPlaybackRate"
        )
    }

    private var activationCount = 0

    func activate() {
        activationCount += 1
        Self.logger.debug("MediaRemote activate. Count: \(self.activationCount, privacy: .public)")
        if activationCount == 1 {
            setWantsNowPlayingNotifications?(true)
            registerForNowPlayingNotifications?(callbackQueue)
            Self.logger.debug("MediaRemote now playing notifications enabled and registered.")
        }
    }

    func deactivate() {
        guard activationCount > 0 else {
            Self.logger.debug("MediaRemote deactivate ignored because count is already zero.")
            return
        }

        activationCount -= 1
        Self.logger.debug("MediaRemote deactivate. Count: \(self.activationCount, privacy: .public)")
        if activationCount == 0 {
            unregisterForNowPlayingNotifications?()
            setWantsNowPlayingNotifications?(false)
            Self.logger.debug("MediaRemote now playing notifications unregistered and disabled.")
        }
    }

    deinit {
        if activationCount > 0 {
            unregisterForNowPlayingNotifications?()
            setWantsNowPlayingNotifications?(false)
            StenoKitDiagnostics.logger.debug("MediaRemote bridge deinit forced unregister cleanup.")
        }
        if let handle {
            dlclose(handle)
        }
    }

    func anyApplicationIsPlaying() async -> Bool? {
        guard let getAnyApplicationIsPlaying else { return nil }
        return await probeRunner.run { callback in
            getAnyApplicationIsPlaying(callbackQueue) { isPlaying in
                callback(isPlaying)
            }
        }
    }

    func nowPlayingApplicationIsPlaying() async -> Bool? {
        guard let getNowPlayingApplicationIsPlaying else { return nil }
        return await probeRunner.run { callback in
            getNowPlayingApplicationIsPlaying(callbackQueue) { isPlaying in
                callback(isPlaying)
            }
        }
    }

    func nowPlayingPlaybackState() async -> Int? {
        guard let getNowPlayingApplicationPlaybackState else { return nil }
        return await probeRunner.run { callback in
            getNowPlayingApplicationPlaybackState(callbackQueue) { playbackState in
                callback(playbackState)
            }
        }
    }

    func nowPlayingPlaybackRate() async -> Double? {
        guard let getNowPlayingInfo, let playbackRateInfoKey else { return nil }
        return await probeRunner.run { callback in
            getNowPlayingInfo(callbackQueue) { info in
                guard let info else {
                    callback(nil)
                    return
                }
                if let rate = info[playbackRateInfoKey] as? Double {
                    callback(rate)
                    return
                }
                if let rate = info[playbackRateInfoKey] as? NSNumber {
                    callback(rate.doubleValue)
                    return
                }
                if let rate = info[NSString(string: playbackRateInfoKey)] as? NSNumber {
                    callback(rate.doubleValue)
                    return
                }
                callback(nil)
            }
        } ?? nil
    }

    func isPlaybackStateAdvancing(_ playbackState: Int) -> Bool? {
        guard let playbackStateIsAdvancingFn else { return nil }
        return playbackStateIsAdvancingFn(playbackState)
    }

    private static func loadSymbol<Symbol>(
        handle: UnsafeMutableRawPointer?,
        named symbolName: String,
        as _: Symbol.Type
    ) -> Symbol? {
        guard let handle, let symbol = dlsym(handle, symbolName) else { return nil }
        return unsafeBitCast(symbol, to: Symbol.self)
    }

    private static func loadCFStringConstant(
        handle: UnsafeMutableRawPointer?,
        named symbolName: String
    ) -> String? {
        guard let handle, let symbol = dlsym(handle, symbolName) else { return nil }
        let pointer = symbol.assumingMemoryBound(to: CFString?.self)
        guard let value = pointer.pointee else { return nil }
        return value as String
    }
}

struct MediaRemoteAsyncProbeRunner {
    let timeout: DispatchTimeInterval
    let timeoutQueue: DispatchQueue

    init(
        timeout: DispatchTimeInterval = .milliseconds(250),
        timeoutQueue: DispatchQueue = DispatchQueue(label: "Steno.MediaRemote.Timeout", qos: .userInitiated)
    ) {
        self.timeout = timeout
        self.timeoutQueue = timeoutQueue
    }

    @MainActor
    func run<Value: Sendable>(
        _ register: (@escaping @Sendable (Value) -> Void) -> Void
    ) async -> Value? {
        await withCheckedContinuation { continuation in
            let gate = ProbeContinuationGate(continuation: continuation)
            timeoutQueue.asyncAfter(deadline: .now() + timeout) {
                gate.resumeOnce(nil)
            }
            register { value in
                gate.resumeOnce(value)
            }
        }
    }
}

private final class ProbeContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    init(continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func resumeOnce(_ value: Value?) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}

private enum SystemMediaKeySender {
    static func sendPlayPause() -> Bool {
        let down = postSystemDefinedMediaEvent(key: Int32(NX_KEYTYPE_PLAY), isKeyDown: true)
        let up = postSystemDefinedMediaEvent(key: Int32(NX_KEYTYPE_PLAY), isKeyDown: false)
        return down && up
    }

    @discardableResult
    private static func postSystemDefinedMediaEvent(key: Int32, isKeyDown: Bool) -> Bool {
        let keyState = isKeyDown ? 0xA : 0xB
        let data1 = Int((key << 16) | (Int32(keyState) << 8))

        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else {
            return false
        }

        event.cgEvent?.post(tap: .cghidEventTap)
        return true
    }
}
#endif
