#if os(macOS)
import Dispatch
import Foundation
import Testing
@testable import StenoKit

private final class StaticPlaybackDetector: MediaPlaybackStateDetector {
    private let result: PlaybackDetectionResult

    init(_ result: PlaybackDetectionResult) {
        self.result = result
    }

    func detect() async -> PlaybackDetectionResult {
        result
    }
}

private final class DelayedPlaybackDetector: MediaPlaybackStateDetector {
    private let result: PlaybackDetectionResult
    private let delayNanoseconds: UInt64

    init(_ result: PlaybackDetectionResult, delayNanoseconds: UInt64) {
        self.result = result
        self.delayNanoseconds = delayNanoseconds
    }

    func detect() async -> PlaybackDetectionResult {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return result
    }
}

@MainActor
private final class FakeMediaRemoteBridge: MediaRemoteBridging {
    var activateCalls = 0
    var deactivateCalls = 0

    var anyApplicationIsPlayingValue: Bool?
    var nowPlayingApplicationIsPlayingValue: Bool?
    var nowPlayingPlaybackStateValue: Int?
    var nowPlayingPlaybackRateValue: Double?
    var playbackStateIsAdvancingValue: Bool?

    func activate() {
        activateCalls += 1
    }

    func deactivate() {
        deactivateCalls += 1
    }

    func anyApplicationIsPlaying() async -> Bool? {
        anyApplicationIsPlayingValue
    }

    func nowPlayingApplicationIsPlaying() async -> Bool? {
        nowPlayingApplicationIsPlayingValue
    }

    func nowPlayingPlaybackState() async -> Int? {
        nowPlayingPlaybackStateValue
    }

    func nowPlayingPlaybackRate() async -> Double? {
        nowPlayingPlaybackRateValue
    }

    func isPlaybackStateAdvancing(_ playbackState: Int) -> Bool? {
        playbackStateIsAdvancingValue
    }
}

@MainActor
private final class MediaKeySendRecorder {
    private(set) var sendCalls = 0
    var nextResult = true

    func send() -> Bool {
        sendCalls += 1
        return nextResult
    }
}

@MainActor
@Test("Media interruption pauses when playback is active")
func mediaInterruptionPausesWhenPlaybackIsActive() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: StaticPlaybackDetector(.playing),
        sendPlayPauseKey: { recorder.send() }
    )

    let token = await service.beginInterruption()

    #expect(token != nil)
    #expect(recorder.sendCalls == 1)
}

@MainActor
@Test("Media interruption pauses when playback is likely active")
func mediaInterruptionPausesWhenPlaybackIsLikelyActive() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: StaticPlaybackDetector(.likelyPlaying),
        sendPlayPauseKey: { recorder.send() }
    )

    let token = await service.beginInterruption()

    #expect(token != nil)
    #expect(recorder.sendCalls == 1)
}

@MainActor
@Test("Media interruption skips pause when playback is not active")
func mediaInterruptionSkipsPauseWhenPlaybackIsNotActive() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: StaticPlaybackDetector(.notPlaying),
        sendPlayPauseKey: { recorder.send() }
    )

    let token = await service.beginInterruption()

    #expect(token == nil)
    #expect(recorder.sendCalls == 0)
}

@MainActor
@Test("Media interruption skips pause when playback state is unknown")
func mediaInterruptionSkipsPauseWhenPlaybackStateIsUnknown() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: StaticPlaybackDetector(.unknown),
        sendPlayPauseKey: { recorder.send() }
    )

    let token = await service.beginInterruption()

    #expect(token == nil)
    #expect(recorder.sendCalls == 0)
}

@MainActor
@Test("Unknown playback state must not start phantom media playback")
func unknownPlaybackStateMustNotStartPhantomMediaPlayback() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: StaticPlaybackDetector(.unknown),
        sendPlayPauseKey: { recorder.send() }
    )

    let token = await service.beginInterruption()

    #expect(token == nil, "Unknown state must not produce a token — sending play/pause would start media")
    #expect(recorder.sendCalls == 0, "No media key must be sent when playback state is unknown")
}

@MainActor
@Test("Media interruption resumes only when the token was active")
func mediaInterruptionResumesOnlyForActiveToken() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: StaticPlaybackDetector(.playing),
        sendPlayPauseKey: { recorder.send() }
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected interruption token for active playback.")
        return
    }

    service.endInterruption(token: token)

    #expect(recorder.sendCalls == 2)
}

@MainActor
@Test("Media interruption ignores invalid or duplicate tokens")
func mediaInterruptionIgnoresInvalidOrDuplicateTokens() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: StaticPlaybackDetector(.playing),
        sendPlayPauseKey: { recorder.send() }
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected interruption token for active playback.")
        return
    }

    service.endInterruption(token: MediaInterruptionToken())
    #expect(recorder.sendCalls == 1)

    service.endInterruption(token: token)
    #expect(recorder.sendCalls == 2)

    service.endInterruption(token: token)
    #expect(recorder.sendCalls == 2)
}

@MainActor
@Test("Detector returns likely playing when weak positives are present")
func detectorReturnsLikelyPlayingForWeakPositives() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.nowPlayingApplicationIsPlayingValue = true
    bridge.anyApplicationIsPlayingValue = false

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .likelyPlaying)
}

@MainActor
@Test("Detector prefers weak positive over ambiguous strong-negative probes")
func detectorPrefersWeakPositiveOverAmbiguousStrongNegativeProbes() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.nowPlayingApplicationIsPlayingValue = true
    bridge.nowPlayingPlaybackRateValue = 0

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .likelyPlaying)
}

@MainActor
@Test("Detector returns playing for strong positive signal only")
func detectorReturnsPlayingForStrongPositiveOnly() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.nowPlayingPlaybackRateValue = 1.0

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .playing)
}

@MainActor
@Test("Detector returns not playing for strong negative signal only")
func detectorReturnsNotPlayingForStrongNegativeOnly() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.nowPlayingPlaybackRateValue = 0

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .notPlaying)
}

@MainActor
@Test("Detector returns unknown for mixed strong positive and strong negative signals")
func detectorReturnsUnknownForMixedStrongSignals() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.nowPlayingPlaybackRateValue = 1.0
    bridge.nowPlayingPlaybackStateValue = 42
    bridge.playbackStateIsAdvancingValue = false

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .unknown)
}

@MainActor
@Test("Detector activates and deactivates bridge exactly once")
func detectorActivatesAndDeactivatesBridgeOnce() async {
    let bridge = FakeMediaRemoteBridge()
    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)

    _ = await detector.detect()

    #expect(bridge.activateCalls == 1)
    #expect(bridge.deactivateCalls == 1)
}

@MainActor
@Test("Cancelled beginInterruption does not send media key")
func cancelledBeginInterruptionDoesNotSendMediaKey() async {
    let recorder = MediaKeySendRecorder()
    let service = MacMediaInterruptionService(
        playbackDetector: DelayedPlaybackDetector(.playing, delayNanoseconds: 50_000_000),
        sendPlayPauseKey: { recorder.send() }
    )

    let task = Task { @MainActor in
        await service.beginInterruption()
    }
    task.cancel()

    let token = await task.value
    #expect(token == nil)
    #expect(recorder.sendCalls == 0)
}

@Test("MediaRemote probe runner ignores callbacks after timeout")
func mediaRemoteProbeRunnerIgnoresLateCallbacks() async {
    let callbackQueue = DispatchQueue(label: "StenoTests.MediaRemote.Callback")
    callbackQueue.suspend()
    var resumedCallbackQueue = false
    defer {
        if !resumedCallbackQueue {
            callbackQueue.resume()
        }
    }

    let runner = MediaRemoteAsyncProbeRunner(
        timeout: .milliseconds(20),
        timeoutQueue: DispatchQueue(label: "StenoTests.MediaRemote.Timeout")
    )

    let value = await runner.run { callback in
        callbackQueue.async {
            callback(true)
        }
        callbackQueue.async {
            callback(false)
        }
    }

    #expect(value == nil)

    // Release queued callbacks after timeout to validate late callbacks are ignored.
    callbackQueue.resume()
    resumedCallbackQueue = true
    try? await Task.sleep(nanoseconds: 50_000_000)
}
#endif
