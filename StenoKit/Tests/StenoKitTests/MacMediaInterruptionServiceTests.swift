#if os(macOS)
import Dispatch
import Foundation
import Testing
@testable import StenoKit

private let primaryTarget = MediaPlaybackTarget(
    processID: 42,
    bundleIdentifier: "com.example.player"
)

private let primaryAudioOutput = MediaAudioOutputTarget(
    processID: 42,
    applicationBundleIdentifier: "com.example.player"
)

private func makeSnapshot(
    target: MediaPlaybackTarget? = primaryTarget,
    contentIdentifier: String? = "item-1",
    detection: PlaybackDetectionResult,
    isPlaying: Bool?,
    playbackState: Int?,
    activeAudioOutputs: [MediaAudioOutputTarget]?,
    unresolvedAudioOutputCount: Int = 0
) -> MediaInterruptionSnapshot {
    MediaInterruptionSnapshot(
        target: target,
        contentIdentifier: contentIdentifier,
        detection: detection,
        nowPlayingIsPlaying: isPlaying,
        playbackState: playbackState,
        audioOutputObservation: activeAudioOutputs.map {
            MediaAudioOutputObservation(
                targets: $0,
                unresolvedProcessCount: unresolvedAudioOutputCount
            )
        }
    )
}

private let confirmedPlayingSnapshot = makeSnapshot(
    detection: .playing,
    isPlaying: true,
    playbackState: 1,
    activeAudioOutputs: [primaryAudioOutput]
)

private let confirmedPausedSnapshot = makeSnapshot(
    detection: .notPlaying,
    isPlaying: false,
    playbackState: 2,
    activeAudioOutputs: []
)

private let confirmedSilentSnapshotWithoutTarget = makeSnapshot(
    target: nil,
    contentIdentifier: nil,
    detection: .notPlaying,
    isPlaying: false,
    playbackState: 2,
    activeAudioOutputs: []
)

@MainActor
private final class FakeMediaInterruptionDriver: MediaInterruptionDriving {
    private var snapshots: [MediaInterruptionSnapshot]
    private let fallbackSnapshot: MediaInterruptionSnapshot
    var sendResults: [Bool]
    var acceptedApplicationsBySend: [[String]] = []
    private(set) var commands: [SemanticMediaCommand] = []
    private(set) var destinations: [MediaPauseDestination] = []
    private(set) var verifiedCommands: [SemanticMediaCommand] = []
    private(set) var verifiedDestinations: [VerifiedMediaResumeDestination] = []
    private(set) var snapshotCallCount = 0
    private(set) var sendCallCount = 0
    var snapshotDelayNanoseconds: UInt64 = 0
    var snapshotGates: [Int: MediaSnapshotGate] = [:]
    var sendGates: [Int: MediaSnapshotGate] = [:]

    init(
        snapshots: [MediaInterruptionSnapshot],
        sendResults: [Bool] = [true]
    ) {
        self.snapshots = snapshots
        self.fallbackSnapshot = snapshots.last ?? makeSnapshot(
            target: nil,
            contentIdentifier: nil,
            detection: .unknown,
            isPlaying: nil,
            playbackState: nil,
            activeAudioOutputs: nil
        )
        self.sendResults = sendResults
    }

    func snapshot() async -> MediaInterruptionSnapshot {
        snapshotCallCount += 1
        if let gate = snapshotGates[snapshotCallCount] {
            await gate.wait()
        }
        if snapshotDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: snapshotDelayNanoseconds)
        }
        guard !snapshots.isEmpty else { return fallbackSnapshot }
        return snapshots.removeFirst()
    }

    func sendPause(
        to destination: MediaPauseDestination
    ) async -> MediaCommandDispatchResult {
        sendCallCount += 1
        commands.append(.pause)
        destinations.append(destination)
        if let gate = sendGates[sendCallCount] {
            await gate.wait()
        }
        let requestedApplications = destination.applicationBundleIdentifiers
        if !acceptedApplicationsBySend.isEmpty {
            return MediaCommandDispatchResult(
                acceptedApplicationBundleIdentifiers: acceptedApplicationsBySend.removeFirst()
            )
        }
        let accepted = sendResults.isEmpty ? true : sendResults.removeFirst()
        return MediaCommandDispatchResult(
            acceptedApplicationBundleIdentifiers: accepted ? requestedApplications : []
        )
    }

    func sendPause(
        to destination: VerifiedMediaResumeDestination
    ) async -> MediaCommandDispatchResult {
        await sendVerified(
            .pause,
            to: destination
        )
    }

    func sendPlay(
        to destination: VerifiedMediaResumeDestination
    ) async -> MediaCommandDispatchResult {
        await sendVerified(.play, to: destination)
    }

    private func sendVerified(
        _ command: SemanticMediaCommand,
        to destination: VerifiedMediaResumeDestination
    ) async -> MediaCommandDispatchResult {
        sendCallCount += 1
        commands.append(command)
        verifiedCommands.append(command)
        verifiedDestinations.append(destination)
        destinations.append(.observedApplications(destination.applicationBundleIdentifiers))
        if let gate = sendGates[sendCallCount] {
            await gate.wait()
        }
        if !acceptedApplicationsBySend.isEmpty {
            return MediaCommandDispatchResult(
                acceptedApplicationBundleIdentifiers: acceptedApplicationsBySend.removeFirst()
            )
        }
        let accepted = sendResults.isEmpty ? true : sendResults.removeFirst()
        return MediaCommandDispatchResult(
            acceptedApplicationBundleIdentifiers: accepted
                ? destination.applicationBundleIdentifiers
                : []
        )
    }
}

@MainActor
private final class FakeAudioOutputMonitor: AudioOutputMonitoring {
    var observation: MediaAudioOutputObservation?

    func observeActiveAudioOutputs(
        excludingProcessID: Int32
    ) -> MediaAudioOutputObservation? {
        observation
    }
}

@MainActor
private final class MediaSnapshotGate {
    private(set) var waitCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isPermanentlyOpen = false

    func wait() async {
        waitCount += 1
        guard !isPermanentlyOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func openPermanently() {
        isPermanentlyOpen = true
        open()
    }
}

private actor MediaSleepGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(
        minimumCount: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private(set) var waitCount = 0
    private var isPermanentlyOpen = false

    func wait() async {
        waitCount += 1
        let readyWaiters = countWaiters.filter { waitCount >= $0.minimumCount }
        countWaiters.removeAll { waitCount >= $0.minimumCount }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
        guard !isPermanentlyOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilCount(
        _ minimumCount: Int,
        timeoutMilliseconds: Int
    ) async -> Bool {
        for _ in 0..<timeoutMilliseconds {
            if waitCount >= minimumCount { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return waitCount >= minimumCount
    }

    func open() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func openPermanently() {
        isPermanentlyOpen = true
        open()
        let pendingCountWaiters = countWaiters
        countWaiters.removeAll()
        for waiter in pendingCountWaiters {
            waiter.continuation.resume()
        }
    }
}

@MainActor
private final class CompletionProbe {
    var didStart = false
    var didComplete = false
}

private actor MediaDelayRecorder {
    private var recordedDelays: [UInt64] = []

    func append(_ delay: UInt64) {
        recordedDelays.append(delay)
    }

    func values() -> [UInt64] {
        recordedDelays
    }
}

@MainActor
private func waitUntil(
    _ predicate: @escaping @MainActor () -> Bool,
    timeoutMilliseconds: Int = 1_000
) async {
    for _ in 0..<timeoutMilliseconds {
        if predicate() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    Issue.record("Timed out waiting for test condition.")
}

@MainActor
private func waitUntilSatisfied(
    _ predicate: @escaping @MainActor () -> Bool,
    timeoutMilliseconds: Int = 1_000
) async -> Bool {
    for _ in 0..<timeoutMilliseconds {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return predicate()
}

@MainActor
private func makeService(driver: FakeMediaInterruptionDriver) -> MacMediaInterruptionService {
    MacMediaInterruptionService(driver: driver, verificationDelays: [0])
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
    var anyApplicationIsPlayingSequence: [Bool?] = []
    var nowPlayingApplicationIsPlayingSequence: [Bool?] = []
    var nowPlayingPlaybackStateSequence: [Int?] = []
    var nowPlayingPlaybackRateSequence: [Double?] = []
    var playbackStateIsAdvancingSequence: [Bool?] = []
    var targetedSendDelayNanoseconds: UInt64 = 0
    var targetedSendResultsByApplication: [String: Bool] = [:]
    private(set) var targetedCommands: [(SemanticMediaCommand, String)] = []
    private(set) var targetedApplications: [String] = []
    private(set) var targetedSendsInFlight = 0
    private(set) var maximumConcurrentTargetedSends = 0

    func activate() {
        activateCalls += 1
    }

    func deactivate() {
        deactivateCalls += 1
    }

    func anyApplicationIsPlaying() async -> Bool? {
        pullNext(from: &anyApplicationIsPlayingSequence, fallback: anyApplicationIsPlayingValue)
    }

    func nowPlayingApplicationIsPlaying() async -> Bool? {
        pullNext(from: &nowPlayingApplicationIsPlayingSequence, fallback: nowPlayingApplicationIsPlayingValue)
    }

    func nowPlayingPlaybackState() async -> Int? {
        pullNext(from: &nowPlayingPlaybackStateSequence, fallback: nowPlayingPlaybackStateValue)
    }

    func nowPlayingPlaybackRate() async -> Double? {
        pullNext(from: &nowPlayingPlaybackRateSequence, fallback: nowPlayingPlaybackRateValue)
    }

    func nowPlayingApplicationPID() async -> Int32? {
        nil
    }

    func nowPlayingApplicationDisplayID() async -> String? {
        nil
    }

    func nowPlayingContentIdentifier() async -> String? {
        nil
    }

    func isPlaybackStateAdvancing(_ playbackState: Int) -> Bool? {
        pullNext(from: &playbackStateIsAdvancingSequence, fallback: playbackStateIsAdvancingValue)
    }

    func send(
        _ command: SemanticMediaCommand,
        toApplicationBundleIdentifier applicationBundleIdentifier: String
    ) async -> Bool {
        targetedCommands.append((command, applicationBundleIdentifier))
        targetedApplications.append(applicationBundleIdentifier)
        targetedSendsInFlight += 1
        maximumConcurrentTargetedSends = max(
            maximumConcurrentTargetedSends,
            targetedSendsInFlight
        )
        if targetedSendDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: targetedSendDelayNanoseconds)
        }
        targetedSendsInFlight -= 1
        return targetedSendResultsByApplication[applicationBundleIdentifier] ?? true
    }

    private func pullNext<Value>(from sequence: inout [Value?], fallback: Value?) -> Value? {
        if !sequence.isEmpty {
            return sequence.removeFirst()
        }
        return fallback
    }
}

@MainActor
@Test("Verified active playback receives semantic Pause and creates a token")
func verifiedActivePlaybackReceivesSemanticPause() async {
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, confirmedPausedSnapshot]
    )
    let service = makeService(driver: driver)

    let token = await service.beginInterruption()

    #expect(token != nil)
    #expect(driver.commands == [.pause])
    #expect(driver.destinations == [.observedApplications(["com.example.player"])])
}

@MainActor
@Test("Initial Pause rejects a producer that exited after the audio snapshot")
func initialPauseRejectsProducerThatExitedAfterAudioSnapshot() async {
    let originalProducer = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts",
        processStartTimeMicroseconds: 100
    )
    let bridge = FakeMediaRemoteBridge()
    bridge.nowPlayingPlaybackRateValue = 1
    let audioOutputMonitor = FakeAudioOutputMonitor()
    audioOutputMonitor.observation = MediaAudioOutputObservation(
        targets: [originalProducer],
        unresolvedProcessCount: 0
    )
    let driver = MacMediaInterruptionDriver(
        bridge: bridge,
        playbackDetector: MultiSignalMediaPlaybackStateDetector(bridge: bridge),
        audioOutputMonitor: audioOutputMonitor,
        applicationResolver: AudioProcessApplicationResolver(
            processPath: { _ in nil },
            bundleIdentifierAtURL: { _ in nil },
            processStartTimeMicroseconds: { _ in nil }
        )
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0]
    )

    let token = await service.beginInterruption()
    if let token {
        await service.endInterruption(token: token)
    }

    #expect(token == nil)
    #expect(
        bridge.targetedCommands.isEmpty,
        "A stale Core Audio producer must be rejected before bundle-targeted Pause dispatch."
    )
}

@MainActor
@Test("Weak playback evidence cannot start paused media")
func weakPlaybackEvidenceCannotStartPausedMedia() async {
    let weakEvidence = makeSnapshot(
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: []
    )
    let driver = FakeMediaInterruptionDriver(snapshots: [weakEvidence])
    let service = makeService(driver: driver)

    let token = await service.beginInterruption()

    #expect(token == nil, "Uncertain playback evidence must not create interruption ownership")
    #expect(driver.commands.isEmpty, "Uncertain evidence must never authorize a media command")
}

@MainActor
@Test("Trusted not-playing evidence overrides lagging Core Audio output")
func trustedNotPlayingEvidenceOverridesLaggingAudioOutput() async {
    let pausedWithLaggingAudioOutput = makeSnapshot(
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [pausedWithLaggingAudioOutput, confirmedPausedSnapshot]
    )
    let service = makeService(driver: driver)

    let token = await service.beginInterruption()

    #expect(token == nil)
    #expect(driver.commands.isEmpty)
}

@MainActor
@Test("Confirmed playback can be paused without content identity")
func confirmedPlaybackCanPauseWithoutContentIdentity() async {
    let unidentifiedPlaying = makeSnapshot(
        contentIdentifier: nil,
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let unidentifiedPaused = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: []
    )
    let driver = FakeMediaInterruptionDriver(snapshots: [unidentifiedPlaying, unidentifiedPaused])
    let service = makeService(driver: driver)

    let token = await service.beginInterruption()

    #expect(token != nil)
    #expect(driver.commands == [.pause])
}

@MainActor
@Test("Active CoreAudio output routes Pause to its owning app when MediaRemote is stale")
func activeCoreAudioOutputRoutesPauseToOwningAppWhenMediaRemoteIsStale() async {
    let chromeOutput = MediaAudioOutputTarget(
        processID: 99,
        applicationBundleIdentifier: "com.google.Chrome"
    )
    let staleButAudible = makeSnapshot(
        target: MediaPlaybackTarget(
            processID: 7,
            bundleIdentifier: "com.apple.podcasts"
        ),
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [chromeOutput]
    )
    let chromePaused = makeSnapshot(
        target: MediaPlaybackTarget(
            processID: 7,
            bundleIdentifier: "com.apple.podcasts"
        ),
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: []
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [staleButAudible, chromePaused]
    )
    let service = makeService(driver: driver)

    let token = await service.beginInterruption()

    #expect(token != nil)
    #expect(driver.commands == [.pause])
    #expect(driver.destinations == [.observedApplications(["com.google.Chrome"])])
}

@MainActor
@Test("Available CoreAudio silence never sends a media command")
func availableCoreAudioSilenceNeverSendsMediaCommand() async {
    let staleMediaRemote = makeSnapshot(
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: []
    )
    let driver = FakeMediaInterruptionDriver(snapshots: [staleMediaRemote])
    let service = makeService(driver: driver)

    let token = await service.beginInterruption()

    #expect(token == nil)
    #expect(driver.commands.isEmpty)
    #expect(driver.destinations.isEmpty)
}

@MainActor
@Test("Unresolved-only active audio output never sends a media command")
func unresolvedOnlyActiveAudioOutputNeverSendsMediaCommand() async {
    let unresolvedOutput = makeSnapshot(
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [],
        unresolvedAudioOutputCount: 1
    )
    let driver = FakeMediaInterruptionDriver(snapshots: [unresolvedOutput])
    let service = makeService(driver: driver)

    let token = await service.beginInterruption()

    #expect(token == nil)
    #expect(driver.commands.isEmpty)
    #expect(driver.destinations.isEmpty)
}

@MainActor
@Test("Pause verification ignores unrelated audio output and owns only the stopped app")
func pauseVerificationIgnoresUnrelatedAudioOutput() async {
    let chromeOutput = MediaAudioOutputTarget(
        processID: 99,
        applicationBundleIdentifier: "com.google.Chrome"
    )
    let musicOutput = MediaAudioOutputTarget(
        processID: 100,
        applicationBundleIdentifier: "com.apple.Music"
    )
    let before = makeSnapshot(
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [chromeOutput]
    )
    let after = makeSnapshot(
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [musicOutput]
    )
    let driver = FakeMediaInterruptionDriver(snapshots: [before, after])
    let service = makeService(driver: driver)

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected ownership for the exact app whose output stopped.")
        return
    }
    #expect(driver.commands == [.pause])
    #expect(driver.destinations == [.observedApplications(["com.google.Chrome"])])
    await service.endInterruption(token: token)
    #expect(driver.commands == [.pause, .play])
    #expect(driver.destinations.last == .observedApplications(["com.google.Chrome"]))
}

@MainActor
@Test("Unavailable CoreAudio never sends a media command")
func unavailableCoreAudioNeverSendsMediaCommand() async {
    let playing = makeSnapshot(
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: nil
    )
    let driver = FakeMediaInterruptionDriver(snapshots: [playing])
    let service = makeService(driver: driver)

    let token = await service.beginInterruption()

    #expect(token == nil)
    #expect(driver.commands.isEmpty)
    #expect(driver.destinations.isEmpty)
}

@MainActor
@Test("Unavailable CoreAudio never retries speculative Pause")
func unavailableCoreAudioNeverRetriesSpeculativePause() async {
    let unavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let driver = FakeMediaInterruptionDriver(snapshots: [unavailable])
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )

    let token = await service.beginInterruption()

    #expect(token == nil)
    #expect(driver.snapshotCallCount == 1)
    #expect(driver.commands.isEmpty)
    #expect(driver.destinations.isEmpty)
}

@MainActor
@Test("Begin returns custody without waiting for the verification ladder")
func beginReturnsCustodyWithoutWaitingForVerificationLadder() async {
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let laggingOpenStream = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let verificationGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: Array(repeating: laggingOpenStream, count: 6)
    )
    // Park the ladder inside its first verification pass.
    driver.snapshotGates[2] = verificationGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )

    let probe = CompletionProbe()
    let begin = Task { @MainActor in
        let token = await service.beginInterruption()
        probe.didComplete = true
        return token
    }

    await waitUntil { verificationGate.waitCount == 1 }
    #expect(driver.commands == [.pause])
    // Custody exists as soon as the app-targeted Pause is accepted, so the caller
    // is released while the opportunistic ladder keeps running.
    await waitUntil { probe.didComplete }

    verificationGate.open()
    guard let token = await begin.value else {
        Issue.record("An accepted Pause of a verified-active application must yield custody.")
        return
    }
    await service.endInterruption(token: token)
    #expect(driver.commands.contains(.play))
}

@MainActor
@Test("A stuck any-application playing signal cannot orphan an accepted Pause")
func stuckAnyApplicationPlayingSignalCannotOrphanAcceptedPause() async {
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    // The any-application playing bit stays true long after real silence, pinning
    // detection at likelyPlaying for the entire capture.
    let stuckWeakPositive = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: Array(repeating: stuckWeakPositive, count: 4)
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("A stuck weak-positive signal must not discard an accepted exact-app Pause.")
        return
    }
    await service.endInterruption(token: token)

    #expect(driver.commands.last == .play)
    #expect(driver.destinations.last == .observedApplications(["com.apple.podcasts"]))
}

@MainActor
@Test("Core Audio teardown slower than the whole verification ladder still resumes at release")
func laggingCoreAudioTeardownBeyondVerificationLadderResumesAtRelease() async {
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts",
        processStartTimeMicroseconds: 1_000
    )
    let audible = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    // The output stream stays open while the application is already silent; teardown
    // can lag far past the last verification pass.
    let silentWithOpenOutputStream = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [audible] + Array(repeating: silentWithOpenOutputStream, count: 6)
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: MacMediaInterruptionService.defaultVerificationDelays
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Pending custody must survive a teardown slower than the delay ladder.")
        return
    }
    await service.endInterruption(token: token)

    #expect(driver.commands.last == .play)
    #expect(driver.verifiedDestinations.last?.expectedProcessTargets == [podcastsOutput])
}

@MainActor
@Test("A paused elected session cannot veto pausing another active application")
func pausedElectedSessionDoesNotShadowSecondActiveApplication() async {
    let electedChromeSession = MediaPlaybackTarget(
        processID: 91,
        bundleIdentifier: "com.google.Chrome"
    )
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    // Chrome owns the elected session with a paused tab while Podcasts is audible.
    let electedSessionPaused = makeSnapshot(
        target: electedChromeSession,
        contentIdentifier: "chrome-item",
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [electedSessionPaused, confirmedSilentSnapshotWithoutTarget]
    )
    let service = makeService(driver: driver)

    let token = await service.beginInterruption()

    #expect(token != nil)
    #expect(driver.destinations == [.observedApplications(["com.apple.podcasts"])])
    #expect(!driver.commands.contains(.play))
}

@MainActor
@Test("Unknown detection with clean Core Audio evidence pauses and resumes the active app")
func unknownDetectionWithCleanCoreAudioEvidencePausesActiveApplication() async {
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    // Lockdown-degraded probes resolve to unknown while Core Audio observation
    // stays clean and unambiguous.
    let unknownButAudible = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: [podcastsOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            unknownButAudible,
            confirmedSilentSnapshotWithoutTarget,
            confirmedSilentSnapshotWithoutTarget,
        ]
    )
    let service = makeService(driver: driver)

    guard let token = await service.beginInterruption() else {
        Issue.record("Clean Core Audio evidence must authorize an exact-app Pause.")
        return
    }
    #expect(driver.destinations == [.observedApplications(["com.apple.podcasts"])])

    await service.endInterruption(token: token)

    #expect(driver.commands == [.pause, .play])
}

@MainActor
@Test("A transient unresolved output process narrows rather than cancels interruption")
func transientUnresolvedOutputProcessNarrowsPauseDestination() async {
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    // A short-lived system output process cannot be resolved to an app bundle.
    let audibleBesideUnresolvedProcess = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput],
        unresolvedAudioOutputCount: 1
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            audibleBesideUnresolvedProcess,
            confirmedSilentSnapshotWithoutTarget,
            confirmedSilentSnapshotWithoutTarget,
        ]
    )
    let service = makeService(driver: driver)

    guard let token = await service.beginInterruption() else {
        Issue.record("A resolved active app must stay a Pause target beside an unresolved process.")
        return
    }
    #expect(driver.destinations == [.observedApplications(["com.apple.podcasts"])])

    await service.endInterruption(token: token)

    #expect(driver.commands == [.pause, .play])
}

@MainActor
@Test("A cancelled owner after an accepted initial Pause compensates with exact-lineage Play")
func cancelledOwnerAfterAcceptedInitialPauseCompensatesWithPlay() async {
    let replacementOutput = MediaAudioOutputTarget(
        processID: primaryAudioOutput.processID + 1,
        applicationBundleIdentifier: primaryAudioOutput.applicationBundleIdentifier
    )
    let activeReplacement = makeSnapshot(
        target: MediaPlaybackTarget(
            processID: primaryTarget.processID + 1,
            bundleIdentifier: primaryTarget.bundleIdentifier
        ),
        contentIdentifier: "item-2",
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [replacementOutput]
    )
    let pauseDispatchGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, activeReplacement, activeReplacement]
    )
    driver.sendGates[1] = pauseDispatchGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )

    let begin = Task { @MainActor in await service.beginInterruption() }
    await waitUntil { pauseDispatchGate.waitCount == 1 }
    #expect(driver.commands == [.pause])
    begin.cancel()
    await Task.yield()
    #expect(!driver.commands.contains(.play))
    pauseDispatchGate.open()

    #expect(await begin.value == nil)
    await waitUntil { driver.commands == [.pause, .play] }
    #expect(driver.verifiedCommands == [.pause, .play])
    #expect(
        driver.verifiedDestinations == [
            VerifiedMediaResumeDestination(
                applicationBundleIdentifiers: [primaryAudioOutput.applicationBundleIdentifier],
                expectedProcessTargets: [primaryAudioOutput]
            ),
            VerifiedMediaResumeDestination(
                applicationBundleIdentifiers: [primaryAudioOutput.applicationBundleIdentifier],
                expectedProcessTargets: [primaryAudioOutput]
            ),
        ]
    )
}

@MainActor
@Test("Cancelling a completed begin preserves the returned owner's custody")
func cancellingCompletedBeginPreservesReturnedCustody() async {
    let verificationGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, confirmedPausedSnapshot]
    )
    driver.snapshotGates[2] = verificationGate
    let service = makeService(driver: driver)

    let begin = Task { @MainActor in
        await service.beginInterruption()
    }
    await waitUntil { verificationGate.waitCount == 1 }
    guard let token = await begin.value else {
        verificationGate.open()
        Issue.record("Accepted pending custody should be returned before verification completes.")
        return
    }

    // Cancellation is not retroactive once begin has completed. The returned
    // token remains a real owner until its consumer releases it explicitly.
    begin.cancel()
    await Task.yield()
    #expect(driver.commands == [.pause])

    let release = Task { @MainActor in
        await service.endInterruption(token: token)
    }
    await Task.yield()
    #expect(driver.commands == [.pause])
    verificationGate.open()

    await release.value
    #expect(driver.commands == [.pause, .play])
    #expect(driver.commands.filter { $0 == .play }.count == 1)
    #expect(driver.verifiedDestinations.last?.expectedProcessTargets == [primaryAudioOutput])
}

@MainActor
@Test("Cancellation at the published-custody handoff releases exactly once")
func cancellationAtPublishedCustodyHandoffReleasesExactlyOnce() async {
    let custodyReturnGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, confirmedPausedSnapshot]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        beforePublishedCustodyReturn: {
            if custodyReturnGate.waitCount == 0 {
                await custodyReturnGate.wait()
            }
        }
    )

    let begin = Task { @MainActor in
        await service.beginInterruption()
    }
    await waitUntil { custodyReturnGate.waitCount == 1 }
    #expect(driver.commands == [.pause])

    begin.cancel()
    custodyReturnGate.open()

    #expect(await begin.value == nil)
    await waitUntil { driver.commands == [.pause, .play] }
    #expect(driver.commands == [.pause, .play])
    #expect(driver.commands.filter { $0 == .play }.count == 1)
    #expect(driver.verifiedDestinations.last?.expectedProcessTargets == [primaryAudioOutput])
}

@MainActor
@Test("A replacement owner prevents compensation from a cancelled Pause transition")
func replacementOwnerPreventsCancelledPauseCompensation() async {
    let replacementOutput = MediaAudioOutputTarget(
        processID: primaryAudioOutput.processID + 1,
        applicationBundleIdentifier: primaryAudioOutput.applicationBundleIdentifier
    )
    let activeReplacement = makeSnapshot(
        target: MediaPlaybackTarget(
            processID: primaryTarget.processID + 1,
            bundleIdentifier: primaryTarget.bundleIdentifier
        ),
        contentIdentifier: "item-2",
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [replacementOutput]
    )
    let pauseDispatchGate = MediaSnapshotGate()
    let verificationGate = MediaSnapshotGate()
    let cancellationProbe = CompletionProbe()
    let finalizationProbe = CompletionProbe()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, activeReplacement]
    )
    driver.sendGates[1] = pauseDispatchGate
    driver.snapshotGates[2] = verificationGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        afterPauseTransitionCancellation: {
            cancellationProbe.didComplete = true
        },
        afterPauseTransitionFinalization: {
            finalizationProbe.didComplete = true
        }
    )

    let cancelledBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    await waitUntil { pauseDispatchGate.waitCount == 1 }
    cancelledBegin.cancel()
    await waitUntil { cancellationProbe.didComplete }

    let replacementBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    pauseDispatchGate.open()
    await waitUntil { verificationGate.waitCount == 1 }

    #expect(await cancelledBegin.value == nil)
    guard let replacementToken = await replacementBegin.value else {
        verificationGate.open()
        Issue.record("The replacement owner should receive accepted pending custody.")
        return
    }
    #expect(driver.commands == [.pause])

    verificationGate.open()
    await waitUntil { finalizationProbe.didComplete }

    #expect(driver.commands == [.pause])
    #expect(!driver.commands.contains(.play))
    await service.endInterruption(token: replacementToken)
    #expect(driver.commands == [.pause])
}

@MainActor
@Test("Observed output receives repeated targeted Pause until every client stops")
func observedOutputReceivesRepeatedPauseUntilEveryClientStops() async {
    let stillAudible = makeSnapshot(
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, stillAudible, confirmedPausedSnapshot]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )

    let token = await service.beginInterruption()

    #expect(token != nil)
    #expect(driver.commands == [.pause, .pause])
    #expect(
        driver.destinations == [
            .observedApplications(["com.example.player"]),
            .observedApplications(["com.example.player"]),
        ]
    )
}

@MainActor
@Test("Targeted Pause fan-out sends to applications concurrently")
func targetedPauseFanoutIsConcurrent() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.targetedSendDelayNanoseconds = 40_000_000
    let driver = MacMediaInterruptionDriver(
        bridge: bridge,
        playbackDetector: MultiSignalMediaPlaybackStateDetector(bridge: bridge),
        audioOutputMonitor: FakeAudioOutputMonitor()
    )

    let dispatch = await driver.sendPause(
        to: .observedApplications(["com.example.Alpha", "com.example.Beta"])
    )

    #expect(
        dispatch.acceptedApplicationBundleIdentifiers == [
            "com.example.Alpha",
            "com.example.Beta",
        ]
    )
    #expect(Set(bridge.targetedApplications) == ["com.example.Alpha", "com.example.Beta"])
    #expect(bridge.maximumConcurrentTargetedSends == 2)
}

@MainActor
@Test("Targeted Pause fan-out reports only applications that accepted the command")
func targetedPauseFanoutReportsOnlyAcceptedApplications() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.targetedSendResultsByApplication = [
        "com.example.Alpha": true,
        "com.example.Beta": false,
    ]
    let driver = MacMediaInterruptionDriver(
        bridge: bridge,
        playbackDetector: MultiSignalMediaPlaybackStateDetector(bridge: bridge),
        audioOutputMonitor: FakeAudioOutputMonitor()
    )

    let dispatch = await driver.sendPause(
        to: .observedApplications(["com.example.Alpha", "com.example.Beta"])
    )

    #expect(dispatch.acceptedApplicationBundleIdentifiers == ["com.example.Alpha"])
    #expect(Set(bridge.targetedApplications) == ["com.example.Alpha", "com.example.Beta"])
}

@MainActor
@Test("Targeted Play rejects a resume destination whose exact process exited")
func targetedPlayRejectsExitedExactProcess() async {
    let bridge = FakeMediaRemoteBridge()
    let driver = MacMediaInterruptionDriver(
        bridge: bridge,
        playbackDetector: MultiSignalMediaPlaybackStateDetector(bridge: bridge),
        audioOutputMonitor: FakeAudioOutputMonitor(),
        applicationResolver: AudioProcessApplicationResolver(
            processPath: { _ in nil },
            bundleIdentifierAtURL: { _ in nil }
        )
    )

    let dispatch = await driver.sendPlay(
        to: VerifiedMediaResumeDestination(
            applicationBundleIdentifiers: [primaryAudioOutput.applicationBundleIdentifier],
            expectedProcessTargets: [primaryAudioOutput]
        )
    )

    #expect(dispatch.acceptedApplicationBundleIdentifiers.isEmpty)
    #expect(bridge.targetedCommands.isEmpty)
}

@MainActor
@Test("Targeted Play accepts a multi-process destination when one original producer survives")
func targetedPlayAcceptsSurvivingOriginalProducer() async {
    let survivingProducer = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let exitedHelper = MediaAudioOutputTarget(
        processID: 63_509,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let bridge = FakeMediaRemoteBridge()
    let driver = MacMediaInterruptionDriver(
        bridge: bridge,
        playbackDetector: MultiSignalMediaPlaybackStateDetector(bridge: bridge),
        audioOutputMonitor: FakeAudioOutputMonitor(),
        applicationResolver: AudioProcessApplicationResolver(
            processPath: { processID in
                processID == survivingProducer.processID
                    ? "/Applications/Podcasts.app/Contents/MacOS/Podcasts"
                    : nil
            },
            bundleIdentifierAtURL: { _ in
                survivingProducer.applicationBundleIdentifier
            }
        )
    )

    let dispatch = await driver.sendPlay(
        to: VerifiedMediaResumeDestination(
            applicationBundleIdentifiers: [survivingProducer.applicationBundleIdentifier],
            expectedProcessTargets: [survivingProducer, exitedHelper]
        )
    )

    #expect(dispatch.acceptedApplicationBundleIdentifiers == ["com.apple.podcasts"])
    #expect(bridge.targetedCommands.count == 1)
    #expect(bridge.targetedCommands.first?.0 == .play)
    #expect(bridge.targetedCommands.first?.1 == "com.apple.podcasts")
}

@MainActor
@Test("Targeted Play rejects a surviving producer plus a reused original PID")
func targetedPlayRejectsReusedOriginalProducerPID() async {
    let survivingProducer = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let reusedProducer = MediaAudioOutputTarget(
        processID: 63_509,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let bridge = FakeMediaRemoteBridge()
    let driver = MacMediaInterruptionDriver(
        bridge: bridge,
        playbackDetector: MultiSignalMediaPlaybackStateDetector(bridge: bridge),
        audioOutputMonitor: FakeAudioOutputMonitor(),
        applicationResolver: AudioProcessApplicationResolver(
            processPath: { processID in
                processID == survivingProducer.processID
                    ? "/Applications/Podcasts.app/Contents/MacOS/Podcasts"
                    : "/Applications/Replacement.app/Contents/MacOS/Replacement"
            },
            bundleIdentifierAtURL: { url in
                url.path.contains("Replacement.app")
                    ? "com.example.replacement"
                    : survivingProducer.applicationBundleIdentifier
            }
        )
    )

    let dispatch = await driver.sendPlay(
        to: VerifiedMediaResumeDestination(
            applicationBundleIdentifiers: [survivingProducer.applicationBundleIdentifier],
            expectedProcessTargets: [survivingProducer, reusedProducer]
        )
    )

    #expect(dispatch.acceptedApplicationBundleIdentifiers.isEmpty)
    #expect(bridge.targetedCommands.isEmpty)
}

@MainActor
@Test("Targeted Play rejects same-bundle PID reuse from a newer process generation")
func targetedPlayRejectsSameBundlePIDReuse() async {
    let originalProducer = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts",
        processStartTimeMicroseconds: 100
    )
    let bridge = FakeMediaRemoteBridge()
    let driver = MacMediaInterruptionDriver(
        bridge: bridge,
        playbackDetector: MultiSignalMediaPlaybackStateDetector(bridge: bridge),
        audioOutputMonitor: FakeAudioOutputMonitor(),
        applicationResolver: AudioProcessApplicationResolver(
            processPath: { _ in
                "/Applications/Podcasts.app/Contents/MacOS/Podcasts"
            },
            bundleIdentifierAtURL: { _ in
                originalProducer.applicationBundleIdentifier
            },
            processStartTimeMicroseconds: { _ in 200 }
        )
    )

    let dispatch = await driver.sendPlay(
        to: VerifiedMediaResumeDestination(
            applicationBundleIdentifiers: [originalProducer.applicationBundleIdentifier],
            expectedProcessTargets: [originalProducer]
        )
    )

    #expect(dispatch.acceptedApplicationBundleIdentifiers.isEmpty)
    #expect(bridge.targetedCommands.isEmpty)
}

@MainActor
@Test("Lineage Pause rejects a destination whose exact process exited")
func lineagePauseRejectsExitedExactProcess() async {
    let bridge = FakeMediaRemoteBridge()
    let driver = MacMediaInterruptionDriver(
        bridge: bridge,
        playbackDetector: MultiSignalMediaPlaybackStateDetector(bridge: bridge),
        audioOutputMonitor: FakeAudioOutputMonitor(),
        applicationResolver: AudioProcessApplicationResolver(
            processPath: { _ in nil },
            bundleIdentifierAtURL: { _ in nil }
        )
    )

    let dispatch = await driver.sendPause(
        to: VerifiedMediaResumeDestination(
            applicationBundleIdentifiers: [primaryAudioOutput.applicationBundleIdentifier],
            expectedProcessTargets: [primaryAudioOutput]
        )
    )

    #expect(dispatch.acceptedApplicationBundleIdentifiers.isEmpty)
    #expect(bridge.targetedCommands.isEmpty)
}

@MainActor
@Test("Targeted Play accepts a resume destination whose exact process still matches")
func targetedPlayAcceptsMatchingExactProcess() async {
    let bridge = FakeMediaRemoteBridge()
    let driver = MacMediaInterruptionDriver(
        bridge: bridge,
        playbackDetector: MultiSignalMediaPlaybackStateDetector(bridge: bridge),
        audioOutputMonitor: FakeAudioOutputMonitor(),
        applicationResolver: AudioProcessApplicationResolver(
            processPath: { processID in
                processID == primaryAudioOutput.processID
                    ? "/Applications/Example.app/Contents/MacOS/Example"
                    : nil
            },
            bundleIdentifierAtURL: { _ in
                primaryAudioOutput.applicationBundleIdentifier
            }
        )
    )

    let dispatch = await driver.sendPlay(
        to: VerifiedMediaResumeDestination(
            applicationBundleIdentifiers: [primaryAudioOutput.applicationBundleIdentifier],
            expectedProcessTargets: [primaryAudioOutput]
        )
    )

    #expect(
        dispatch.acceptedApplicationBundleIdentifiers
            == [primaryAudioOutput.applicationBundleIdentifier]
    )
    #expect(bridge.targetedCommands.count == 1)
    #expect(bridge.targetedCommands.first?.0 == .play)
    #expect(
        bridge.targetedCommands.first?.1
            == primaryAudioOutput.applicationBundleIdentifier
    )
}

@MainActor
@Test("Lineage Pause accepts a destination whose exact process still matches")
func lineagePauseAcceptsMatchingExactProcess() async {
    let bridge = FakeMediaRemoteBridge()
    let driver = MacMediaInterruptionDriver(
        bridge: bridge,
        playbackDetector: MultiSignalMediaPlaybackStateDetector(bridge: bridge),
        audioOutputMonitor: FakeAudioOutputMonitor(),
        applicationResolver: AudioProcessApplicationResolver(
            processPath: { processID in
                processID == primaryAudioOutput.processID
                    ? "/Applications/Example.app/Contents/MacOS/Example"
                    : nil
            },
            bundleIdentifierAtURL: { _ in
                primaryAudioOutput.applicationBundleIdentifier
            }
        )
    )

    let dispatch = await driver.sendPause(
        to: VerifiedMediaResumeDestination(
            applicationBundleIdentifiers: [primaryAudioOutput.applicationBundleIdentifier],
            expectedProcessTargets: [primaryAudioOutput]
        )
    )

    #expect(
        dispatch.acceptedApplicationBundleIdentifiers
            == [primaryAudioOutput.applicationBundleIdentifier]
    )
    #expect(bridge.targetedCommands.count == 1)
    #expect(bridge.targetedCommands.first?.0 == .pause)
    #expect(
        bridge.targetedCommands.first?.1
            == primaryAudioOutput.applicationBundleIdentifier
    )
}

@MainActor
@Test("Partial Pause acceptance resumes only the accepted and verified app")
func partialPauseAcceptanceOwnsOnlyAcceptedVerifiedApplication() async {
    let alpha = MediaAudioOutputTarget(
        processID: 10,
        applicationBundleIdentifier: "com.example.Alpha"
    )
    let beta = MediaAudioOutputTarget(
        processID: 11,
        applicationBundleIdentifier: "com.example.Beta"
    )
    let before = makeSnapshot(
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [alpha, beta]
    )
    let after = makeSnapshot(
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [beta]
    )
    let driver = FakeMediaInterruptionDriver(snapshots: [before, after])
    driver.acceptedApplicationsBySend = [["com.example.Alpha"]]
    let service = makeService(driver: driver)

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected ownership for accepted, verified Alpha Pause.")
        return
    }
    await service.endInterruption(token: token)

    #expect(driver.commands == [.pause, .play])
    #expect(
        driver.destinations == [
            .observedApplications(["com.example.Alpha", "com.example.Beta"]),
            .observedApplications(["com.example.Alpha"]),
        ]
    )
}

@MainActor
@Test("Partial immediate Pause verification keeps per-application custody")
func partialImmediatePauseVerificationCreatesNoResumeOwnership() async {
    let alpha = MediaAudioOutputTarget(
        processID: 10,
        applicationBundleIdentifier: "com.example.Alpha"
    )
    let beta = MediaAudioOutputTarget(
        processID: 11,
        applicationBundleIdentifier: "com.example.Beta"
    )
    let before = makeSnapshot(
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [alpha, beta]
    )
    let betaStillActive = makeSnapshot(
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [beta]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [before, betaStillActive, betaStillActive]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )

    let token = await service.beginInterruption()

    #expect(
        token != nil,
        "Alpha verified and Beta stayed pending; partial verification is partial ownership."
    )
    #expect(driver.commands == [.pause, .pause])
    #expect(
        driver.destinations == [
            .observedApplications(["com.example.Alpha", "com.example.Beta"]),
            .observedApplications(["com.example.Beta"]),
        ]
    )
    #expect(driver.verifiedCommands == [.pause, .pause])
    #expect(
        driver.verifiedDestinations == [
            VerifiedMediaResumeDestination(
                applicationBundleIdentifiers: [
                    "com.example.Alpha",
                    "com.example.Beta",
                ],
                expectedProcessTargets: [alpha, beta]
            ),
            VerifiedMediaResumeDestination(
                applicationBundleIdentifiers: ["com.example.Beta"],
                expectedProcessTargets: [beta]
            ),
        ]
    )
}

@Test("Audio helper process resolves to its outer owning app bundle")
func audioHelperProcessResolvesToOuterOwningAppBundle() {
    let chromeAppPath = "/Applications/Google Chrome.app"
    let helperPath = chromeAppPath
        + "/Contents/Frameworks/Google Chrome Framework.framework"
        + "/Versions/150/Helpers/Google Chrome Helper.app"
        + "/Contents/MacOS/Google Chrome Helper"
    let resolver = AudioProcessApplicationResolver(
        processPath: { processID in
            #expect(processID == 81955)
            return helperPath
        },
        bundleIdentifierAtURL: { url in
            switch url.path {
            case chromeAppPath:
                return "com.google.Chrome"
            default:
                return "com.google.Chrome.helper"
            }
        }
    )

    #expect(
        resolver.applicationBundleIdentifier(
            for: 81955
        ) == "com.google.Chrome"
    )
}

@Test("Active audio targets bind the producer process generation")
func activeAudioTargetsBindProcessGeneration() {
    let builder = ActiveAudioProcessObservationBuilder(
        applicationResolver: AudioProcessApplicationResolver(
            processPath: { processID in
                #expect(processID == 63_508)
                return "/Applications/Podcasts.app/Contents/MacOS/Podcasts"
            },
            bundleIdentifierAtURL: { _ in "com.apple.podcasts" },
            processStartTimeMicroseconds: { processID in
                #expect(processID == 63_508)
                return 123_456
            }
        )
    )

    let observation = builder.makeObservation(
        from: [ActiveAudioProcessRecord(processID: 63_508)],
        excludingProcessID: 99
    )

    #expect(observation.unresolvedProcessCount == 0)
    #expect(observation.targets == [
        MediaAudioOutputTarget(
            processID: 63_508,
            applicationBundleIdentifier: "com.apple.podcasts",
            processStartTimeMicroseconds: 123_456
        ),
    ])
}

@Test("Audio output without a process-generation anchor remains unresolved")
func activeAudioTargetWithoutProcessGenerationIsUnresolved() {
    let builder = ActiveAudioProcessObservationBuilder(
        applicationResolver: AudioProcessApplicationResolver(
            processPath: { _ in
                "/Applications/Podcasts.app/Contents/MacOS/Podcasts"
            },
            bundleIdentifierAtURL: { _ in "com.apple.podcasts" },
            processStartTimeMicroseconds: { _ in nil }
        )
    )

    let observation = builder.makeObservation(
        from: [ActiveAudioProcessRecord(processID: 63_508)],
        excludingProcessID: 99
    )

    #expect(observation.unresolvedProcessCount == 1)
    #expect(observation.targets.isEmpty)
}

@Test("Default process resolver reads a stable generation for the current process")
func defaultResolverReadsCurrentProcessGeneration() {
    let processID = Int32(ProcessInfo.processInfo.processIdentifier)
    let resolver = AudioProcessApplicationResolver()

    #expect(resolver.processStartTimeMicroseconds(for: processID) != nil)
}

@Test("Active audio PID and path lookup failures are counted as unresolved ownership")
func activeAudioPIDLookupFailureCountsAsUnresolvedOwnership() {
    let builder = ActiveAudioProcessObservationBuilder(
        applicationResolver: AudioProcessApplicationResolver(
            processPath: { _ in nil },
            bundleIdentifierAtURL: { _ in nil }
        )
    )

    let observation = builder.makeObservation(
        from: [
            ActiveAudioProcessRecord(
                processID: nil
            ),
            ActiveAudioProcessRecord(
                processID: 42
            ),
        ],
        excludingProcessID: 99
    )

    #expect(observation.unresolvedProcessCount == 2)
    #expect(observation.targets.isEmpty)
}

@MainActor
@Test("A later silent snapshot is never consumed to retroactively verify a Pause")
func laterSilenceCannotAuthorizeUnresolvedPause() async {
    let unresolvedSnapshot = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, unresolvedSnapshot, confirmedPausedSnapshot]
    )
    let service = makeService(driver: driver)

    let token = await service.beginInterruption()

    #expect(token != nil, "Ambiguous verification evidence keeps custody pending until release.")
    #expect(driver.commands == [.pause])
    #expect(!driver.commands.contains(.play))
    #expect(driver.snapshotCallCount == 2)
}

@MainActor
@Test("Lost Core Audio observation retains pending custody without an early Play")
func unresolvedPauseCreatesNoResumeOwnershipOrPlay() async {
    let unresolvedSnapshot = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, unresolvedSnapshot, unresolvedSnapshot]
    )
    let service = makeService(driver: driver)

    let token = await service.beginInterruption()

    #expect(token != nil, "Unavailable observation is not evidence that custody was lost.")
    #expect(driver.commands == [.pause])
    #expect(!driver.commands.contains(.play))
}

@MainActor
@Test("The production Pause verification window never compensates with Play")
func productionPauseVerificationWindowNeverCompensatesWithPlay() async {
    let productionVerificationDelays = MacMediaInterruptionService.defaultVerificationDelays
    #expect(productionVerificationDelays == [
        80_000_000,
        120_000_000,
        200_000_000,
        400_000_000,
        800_000_000,
    ])
    let delayRecorder = MediaDelayRecorder()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot]
            + Array(repeating: confirmedPlayingSnapshot, count: 5)
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: productionVerificationDelays,
        sleep: { delay in
            await delayRecorder.append(delay)
        }
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("An accepted Pause of a verified-active application takes custody immediately.")
        return
    }

    // The opportunistic ladder keeps observing while the capture stays open.
    // Confirmed exact-app playing evidence contradicts custody pass by pass,
    // and no pass may compensate with Play while the owner remains.
    await waitUntil { driver.snapshotCallCount == 6 }
    #expect(await delayRecorder.values() == productionVerificationDelays)
    #expect(driver.commands == Array(repeating: .pause, count: 5))
    #expect(!driver.commands.contains(.play))

    // Custody was contradicted and dropped, so release must not Play either.
    await service.endInterruption(token: token)
    #expect(!driver.commands.contains(.play))
}

@MainActor
@Test("Production Pause verification uses its full window before release proves silence")
func productionPauseVerificationUsesFullWindowBeforeReleaseProof() async {
    let pausedTransitionWithLaggingOutput = makeSnapshot(
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let delayRecorder = MediaDelayRecorder()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot]
            + Array(repeating: pausedTransitionWithLaggingOutput, count: 5)
            + [confirmedPausedSnapshot]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: MacMediaInterruptionService.defaultVerificationDelays,
        sleep: { delay in
            await delayRecorder.append(delay)
        }
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("The accepted Pause should remain pending through the full verification window.")
        return
    }

    // Custody is handed back immediately; the full production window is still
    // consumed by the ladder while the capture stays open.
    await waitUntil { driver.snapshotCallCount == 6 }
    #expect(await delayRecorder.values() == MacMediaInterruptionService.defaultVerificationDelays)
    #expect(driver.commands == Array(repeating: .pause, count: 5))

    await service.endInterruption(token: token)
    #expect(driver.commands == Array(repeating: .pause, count: 5) + [.play])
}

@MainActor
@Test("Trusted exact-app paused state defers Play until release while Core Audio output lags")
func trustedPausedStateOwnsInterruptionWhileAudioOutputLags() async {
    let laggingPausedSnapshot = makeSnapshot(
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, laggingPausedSnapshot, confirmedPlayingSnapshot]
    )
    let service = makeService(driver: driver)

    guard let token = await service.beginInterruption() else {
        Issue.record("The exact target's trusted paused state should retain interruption ownership.")
        return
    }

    #expect(driver.commands == [.pause])

    await service.endInterruption(token: token)

    #expect(driver.commands == [.pause, .play])
    #expect(
        driver.destinations == [
            .observedApplications(["com.example.player"]),
            .observedApplications(["com.example.player"]),
        ]
    )
}

@MainActor
@Test("Lagging exact-app Pause verification resumes only after release proves silence")
func laggingExactAppPauseVerificationResumesAfterReleaseProvesSilence() async {
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let playingWithoutTarget = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let pausedWithLaggingAudioOutput = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            playingWithoutTarget,
            pausedWithLaggingAudioOutput,
            pausedWithLaggingAudioOutput,
            confirmedSilentSnapshotWithoutTarget,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("The accepted exact-app Pause should retain pending custody until capture release.")
        return
    }

    #expect(driver.commands == [.pause, .pause])
    await service.endInterruption(token: token)
    #expect(driver.commands == [.pause, .pause, .play])
    #expect(
        driver.destinations == [
            .observedApplications(["com.apple.podcasts"]),
            .observedApplications(["com.apple.podcasts"]),
            .observedApplications(["com.apple.podcasts"]),
        ]
    )
}

@MainActor
@Test("Lagging Pause tracks every exact producer process for one application")
func laggingPauseTracksMultipleProducerProcessesForOneApplication() async {
    let firstProducer = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let secondProducer = MediaAudioOutputTarget(
        processID: 63_509,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let playing = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [firstProducer, secondProducer]
    )
    let laggingPause = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [firstProducer, secondProducer]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [playing, laggingPause, confirmedSilentSnapshotWithoutTarget]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0]
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected exact multi-process pending custody.")
        return
    }
    await service.endInterruption(token: token)

    #expect(driver.commands == [.pause, .play])
    #expect(
        driver.verifiedDestinations.last?.expectedProcessTargets
            == [firstProducer, secondProducer]
    )
}

@MainActor
@Test("Lagging multi-process Pause rejects a replacement producer PID")
func laggingMultiProcessPauseRejectsReplacementProducer() async {
    let firstProducer = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let secondProducer = MediaAudioOutputTarget(
        processID: 63_509,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let replacementProducer = MediaAudioOutputTarget(
        processID: 63_510,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let playing = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [firstProducer, secondProducer]
    )
    let replacement = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [firstProducer, replacementProducer]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [playing, replacement]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0]
    )

    let token = await service.beginInterruption()

    #expect(token == nil)
    #expect(driver.commands == [.pause])
    #expect(!driver.commands.contains(.play))
}

@MainActor
@Test("Repeated ambiguous exact-app snapshots resume at release under preserved lineage")
func repeatedUnknownExactAppSnapshotsDoNotAuthorizePlay() async {
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let playingWithoutTarget = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let pausedTransitionWithLaggingOutput = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            playingWithoutTarget,
            pausedTransitionWithLaggingOutput,
            pausedTransitionWithLaggingOutput,
            pausedTransitionWithLaggingOutput,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected pending custody while the accepted Pause remains ambiguous.")
        return
    }

    await service.endInterruption(token: token)

    #expect(driver.commands == [.pause, .pause, .play])
    #expect(
        driver.destinations.last == .observedApplications(["com.apple.podcasts"]),
        "Resume must stay bound to the exact application Steno paused."
    )
}

@MainActor
@Test("Lagging exact-app Pause resumes at release despite drifting elected-session evidence")
func laggingExactAppPauseVerificationDoesNotResumeWithoutReleaseProof() async {
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let playingWithoutTarget = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let ambiguousWithLaggingAudioOutput = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let driftedReleaseEvidence = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 3,
        activeAudioOutputs: [podcastsOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            playingWithoutTarget,
            ambiguousWithLaggingAudioOutput,
            ambiguousWithLaggingAudioOutput,
            driftedReleaseEvidence,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Expected pending custody for the accepted exact-app Pause.")
        return
    }

    #expect(driver.commands == [.pause, .pause])
    await service.endInterruption(token: token)
    #expect(
        driver.commands == [.pause, .pause, .play],
        "Elected-session playback-state drift is not per-app evidence and cannot strand a pause."
    )
}

@MainActor
@Test("Pending release ignores an elected-session replacement process")
func pendingReleaseRejectsReplacementProcess() async {
    let playingWithTarget = makeSnapshot(
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let ambiguousWithSameTarget = makeSnapshot(
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let replacementTarget = MediaPlaybackTarget(
        processID: primaryTarget.processID + 1,
        bundleIdentifier: primaryTarget.bundleIdentifier
    )
    let replacementPaused = makeSnapshot(
        target: replacementTarget,
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            playingWithTarget,
            ambiguousWithSameTarget,
            ambiguousWithSameTarget,
            replacementPaused,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )
    guard let token = await service.beginInterruption() else {
        Issue.record("Expected pending custody before the replacement process appeared.")
        return
    }

    await service.endInterruption(token: token)

    // The elected session naming a different process is not Core Audio evidence,
    // so custody survives and the exact producer is resumed once.
    #expect(driver.commands.filter { $0 == .play }.count == 1)
}

@MainActor
@Test("Pending release ignores a silent elected-session replacement process")
func pendingReleaseRejectsSilentReplacementProcess() async {
    let playingWithTarget = makeSnapshot(
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let ambiguousWithSameTarget = makeSnapshot(
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let replacementTarget = MediaPlaybackTarget(
        processID: primaryTarget.processID + 1,
        bundleIdentifier: primaryTarget.bundleIdentifier
    )
    let silentReplacement = makeSnapshot(
        target: replacementTarget,
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: []
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            playingWithTarget,
            ambiguousWithSameTarget,
            ambiguousWithSameTarget,
            silentReplacement,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )
    guard let token = await service.beginInterruption() else {
        Issue.record("Expected pending custody before the replacement process appeared.")
        return
    }

    await service.endInterruption(token: token)

    // The elected session naming a different process is not Core Audio evidence,
    // so custody survives and the exact producer is resumed once.
    #expect(driver.commands.filter { $0 == .play }.count == 1)
}

@MainActor
@Test("Pending release rejects stale target evidence when output moves to a same-bundle process")
func pendingReleaseRejectsStaleTargetWithReplacementOutput() async {
    let ambiguousOriginal = makeSnapshot(
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let replacementOutput = MediaAudioOutputTarget(
        processID: primaryAudioOutput.processID + 1,
        applicationBundleIdentifier: primaryAudioOutput.applicationBundleIdentifier
    )
    let staleTargetWithReplacementOutput = makeSnapshot(
        target: primaryTarget,
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [replacementOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            ambiguousOriginal,
            ambiguousOriginal,
            staleTargetWithReplacementOutput,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )
    guard let token = await service.beginInterruption() else {
        Issue.record("Expected pending custody before output moved to a replacement process.")
        return
    }

    await service.endInterruption(token: token)

    #expect(driver.commands == [.pause, .pause])
    #expect(!driver.commands.contains(.play))
}

@MainActor
@Test("Pending release accepts Core Audio teardown when the elected session disappears")
func pendingReleaseRejectsKnownTargetDisappearance() async {
    let ambiguousOriginal = makeSnapshot(
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let targetDisappeared = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: []
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, ambiguousOriginal, targetDisappeared]
    )
    let service = makeService(driver: driver)
    guard let token = await service.beginInterruption() else {
        Issue.record("Expected pending custody before target evidence disappeared.")
        return
    }

    await service.endInterruption(token: token)

    #expect(
        driver.commands == [.pause, .play],
        "Observed output teardown verifies the pause even when the elected session vanishes."
    )
}

@MainActor
@Test("Immediate Pause verification ignores an elected-session replacement process")
func immediatePauseVerificationRejectsReplacementTarget() async {
    let replacementTarget = MediaPlaybackTarget(
        processID: primaryTarget.processID + 1,
        bundleIdentifier: primaryTarget.bundleIdentifier
    )
    let replacementPaused = makeSnapshot(
        target: replacementTarget,
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: []
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, replacementPaused]
    )
    let service = makeService(driver: driver)

    guard let token = await service.beginInterruption() else {
        Issue.record("Elected-session identity is advisory and must not discard custody.")
        return
    }
    #expect(driver.commands == [.pause])
    #expect(!driver.commands.contains(.play), "No Play may be emitted while capture is open.")

    await service.endInterruption(token: token)

    #expect(driver.commands.filter { $0 == .play }.count == 1)
}

@MainActor
@Test("Immediate Pause verification rejects stale target evidence when output moves to a same-bundle process")
func immediatePauseVerificationRejectsStaleTargetWithReplacementOutput() async {
    let replacementOutput = MediaAudioOutputTarget(
        processID: primaryAudioOutput.processID + 1,
        applicationBundleIdentifier: primaryAudioOutput.applicationBundleIdentifier
    )
    let staleTargetWithReplacementOutput = makeSnapshot(
        target: primaryTarget,
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [replacementOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, staleTargetWithReplacementOutput]
    )
    let service = makeService(driver: driver)

    let token = await service.beginInterruption()

    #expect(token == nil)
    #expect(driver.commands == [.pause])
    #expect(!driver.commands.contains(.play))
}

@MainActor
@Test("Immediate Pause verification accepts teardown when the elected session disappears")
func immediatePauseVerificationRejectsKnownTargetDisappearance() async {
    let targetDisappeared = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: []
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, targetDisappeared, targetDisappeared]
    )
    let service = makeService(driver: driver)

    guard let token = await service.beginInterruption() else {
        Issue.record("Observed output teardown must verify the pause on its own evidence.")
        return
    }
    #expect(driver.commands == [.pause])

    await service.endInterruption(token: token)

    #expect(driver.commands == [.pause, .play])
}

@MainActor
@Test("Immediate Pause verification ignores loss of elected content identity")
func immediatePauseVerificationRejectsKnownContentDisappearance() async {
    let contentDisappeared = makeSnapshot(
        target: primaryTarget,
        contentIdentifier: nil,
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: []
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, contentDisappeared]
    )
    let service = makeService(driver: driver)

    guard let token = await service.beginInterruption() else {
        Issue.record("Elected-session identity is advisory and must not discard custody.")
        return
    }
    #expect(driver.commands == [.pause])
    #expect(!driver.commands.contains(.play), "No Play may be emitted while capture is open.")

    await service.endInterruption(token: token)

    #expect(driver.commands.filter { $0 == .play }.count == 1)
}

@MainActor
@Test("A strong-negative target cannot verify Pause while a same-bundle sibling still outputs audio")
func strongNegativeTargetRejectsActiveSameBundleSibling() async {
    let siblingOutput = MediaAudioOutputTarget(
        processID: primaryAudioOutput.processID + 1,
        applicationBundleIdentifier: primaryAudioOutput.applicationBundleIdentifier
    )
    let before = makeSnapshot(
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [primaryAudioOutput, siblingOutput]
    )
    let targetPausedWhileSiblingRemainsActive = makeSnapshot(
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [siblingOutput]
    )
    let replacementSibling = MediaAudioOutputTarget(
        processID: siblingOutput.processID + 1,
        applicationBundleIdentifier: siblingOutput.applicationBundleIdentifier
    )
    let siblingWasReplaced = makeSnapshot(
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [replacementSibling]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [before, targetPausedWhileSiblingRemainsActive, siblingWasReplaced]
    )
    let service = makeService(driver: driver)

    guard let token = await service.beginInterruption() else {
        Issue.record("An accepted Pause of a verified-active app keeps custody pending.")
        return
    }
    #expect(driver.commands == [.pause])

    // Custody is pending rather than verified, so release re-checks the lineage and
    // discards ownership once the surviving producer is replaced.
    await service.endInterruption(token: token)

    #expect(driver.commands == [.pause])
    #expect(!driver.commands.contains(.play))
}

@Test("Paused lineage rejects empty Core Audio while playback evidence stays positive")
func pausedLineageRejectsContradictoryPositivePlaybackEvidence() {
    let destination = VerifiedMediaResumeDestination(
        applicationBundleIdentifiers: [primaryTarget.bundleIdentifier],
        expectedProcessTargets: [primaryAudioOutput]
    )
    let contradictorySnapshot = makeSnapshot(
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: []
    )

    #expect(!contradictorySnapshot.confirmsPausedProcessLineage(destination))
}

@Test("Unrelated playback cannot hide an exact application's completed re-Pause")
func unrelatedPlaybackDoesNotHideCompletedRePause() {
    let destination = VerifiedMediaResumeDestination(
        applicationBundleIdentifiers: [primaryTarget.bundleIdentifier],
        expectedProcessTargets: [primaryAudioOutput]
    )
    let unrelatedTarget = MediaPlaybackTarget(
        processID: 77,
        bundleIdentifier: "com.example.other"
    )
    let unrelatedOutput = MediaAudioOutputTarget(
        processID: unrelatedTarget.processID,
        applicationBundleIdentifier: unrelatedTarget.bundleIdentifier
    )
    let unrelatedPlaying = makeSnapshot(
        target: unrelatedTarget,
        contentIdentifier: "other-item",
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [unrelatedOutput]
    )

    #expect(unrelatedPlaying.confirmsPausedProcessLineage(destination))
}

@MainActor
@Test("Pause verification never retries against a same-bundle replacement process")
func pauseVerificationDoesNotRetryAgainstReplacementProcess() async {
    let replacementTarget = MediaPlaybackTarget(
        processID: primaryTarget.processID + 1,
        bundleIdentifier: primaryTarget.bundleIdentifier
    )
    let replacementOutput = MediaAudioOutputTarget(
        processID: primaryAudioOutput.processID + 1,
        applicationBundleIdentifier: primaryAudioOutput.applicationBundleIdentifier
    )
    let activeReplacement = makeSnapshot(
        target: replacementTarget,
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [replacementOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, activeReplacement, activeReplacement]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )

    let token = await service.beginInterruption()

    #expect(token == nil)
    #expect(
        driver.commands == [.pause],
        "A replaced process must not receive a bundle-scoped retry Pause."
    )
    #expect(
        driver.verifiedDestinations == [
            VerifiedMediaResumeDestination(
                applicationBundleIdentifiers: [primaryAudioOutput.applicationBundleIdentifier],
                expectedProcessTargets: [primaryAudioOutput]
            ),
        ]
    )
    #expect(!driver.commands.contains(.play))
}

@MainActor
@Test("Strong playing evidence retains exact-app custody through lagging verification")
func strongPlayingEvidenceRetainsCustodyThroughLaggingVerification() async {
    let stronglyPlaying = makeSnapshot(
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let pausedTransitionWithLaggingOutput = makeSnapshot(
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            stronglyPlaying,
            pausedTransitionWithLaggingOutput,
            pausedTransitionWithLaggingOutput,
            confirmedPausedSnapshot,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Strong playing evidence should retain exact-app custody.")
        return
    }

    await service.endInterruption(token: token)
    #expect(driver.commands == [.pause, .pause, .play])
}

@MainActor
@Test("Confirmed likely playback without a now-playing Boolean retains exact-app custody")
func likelyPlaybackWithoutBooleanRetainsExactAppCustody() async {
    let likelyPlaying = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let pausedTransitionWithLaggingOutput = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            likelyPlaying,
            pausedTransitionWithLaggingOutput,
            pausedTransitionWithLaggingOutput,
            confirmedSilentSnapshotWithoutTarget,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Confirmed exact-app playback should retain custody without a Boolean probe.")
        return
    }

    await service.endInterruption(token: token)
    #expect(driver.commands == [.pause, .pause, .play])
}

@MainActor
@Test("Rapid restart inherits pending custody without Play under the new owner")
func rapidRestartInheritsPendingCustodyWithoutStalePlay() async {
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let playingWithoutTarget = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let ambiguousWithLaggingAudioOutput = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let releaseGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            playingWithoutTarget,
            ambiguousWithLaggingAudioOutput,
            ambiguousWithLaggingAudioOutput,
            confirmedSilentSnapshotWithoutTarget,
        ]
    )
    driver.snapshotGates[4] = releaseGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected pending custody for the first capture.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { releaseGate.waitCount == 1 }

    let secondToken = await service.beginInterruption()
    releaseGate.open()
    await firstEnd.value

    guard let secondToken else {
        Issue.record("The rapid restart should inherit pending custody.")
        return
    }
    #expect(driver.commands == [.pause, .pause])

    await service.endInterruption(token: secondToken)
    #expect(driver.commands == [.pause, .pause, .play])
}

@MainActor
@Test("Rapid restart defers Play until exact release silence is proved")
func rapidRestartDefersPlayUntilReleaseSilenceProof() async {
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let playingWithoutTarget = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let pausedTransitionWithLaggingOutput = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let releaseGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            playingWithoutTarget,
            pausedTransitionWithLaggingOutput,
            pausedTransitionWithLaggingOutput,
            confirmedSilentSnapshotWithoutTarget,
        ]
    )
    driver.snapshotGates[4] = releaseGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected exact-app pending custody for the first capture.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { releaseGate.waitCount == 1 }
    guard let secondToken = await service.beginInterruption() else {
        Issue.record("Expected the rapid restart to join pending custody.")
        releaseGate.open()
        await firstEnd.value
        return
    }

    releaseGate.open()
    await firstEnd.value
    #expect(driver.commands == [.pause, .pause])

    await service.endInterruption(token: secondToken)
    #expect(driver.commands == [.pause, .pause, .play])
}

@MainActor
@Test("Rapid restart retains pending custody when an older release snapshot drifts")
func rapidRestartRetainsPendingCustodyAcrossDriftedRelease() async {
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let playingWithoutTarget = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let pausedTransitionWithLaggingOutput = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let driftedReleaseEvidence = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 3,
        activeAudioOutputs: [podcastsOutput]
    )
    let releaseGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            playingWithoutTarget,
            pausedTransitionWithLaggingOutput,
            pausedTransitionWithLaggingOutput,
            driftedReleaseEvidence,
            confirmedSilentSnapshotWithoutTarget,
        ]
    )
    driver.snapshotGates[4] = releaseGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected pending custody for the first capture.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { releaseGate.waitCount == 1 }
    guard let secondToken = await service.beginInterruption() else {
        Issue.record("Expected the rapid restart to join pending custody.")
        releaseGate.open()
        await firstEnd.value
        return
    }

    releaseGate.open()
    await firstEnd.value
    #expect(driver.commands == [.pause, .pause])

    await service.endInterruption(token: secondToken)
    #expect(driver.commands == [.pause, .pause, .play])
}

@MainActor
@Test("Rapid restart discards pending custody when release output moves to a replacement process")
func rapidRestartDiscardsPendingCustodyAfterReleaseProcessReplacement() async {
    let originalOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let replacementOutput = MediaAudioOutputTarget(
        processID: originalOutput.processID + 1,
        applicationBundleIdentifier: originalOutput.applicationBundleIdentifier
    )
    let playingOriginal = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [originalOutput]
    )
    let ambiguousOriginal = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [originalOutput]
    )
    let ambiguousReplacement = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [replacementOutput]
    )
    let releaseGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            playingOriginal,
            ambiguousOriginal,
            ambiguousReplacement,
            confirmedSilentSnapshotWithoutTarget,
        ]
    )
    driver.snapshotGates[3] = releaseGate
    let service = makeService(driver: driver)
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected pending custody for the original process.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { releaseGate.waitCount == 1 }
    guard let secondToken = await service.beginInterruption() else {
        Issue.record("Expected the rapid restart to join while release verification was pending.")
        releaseGate.open()
        await firstEnd.value
        return
    }
    releaseGate.open()
    await firstEnd.value

    await service.endInterruption(token: secondToken)

    #expect(driver.commands == [.pause])
    #expect(!driver.commands.contains(.play))
}

@MainActor
@Test("Rapid restart release checks serialize and resume at most once")
func rapidRestartReleaseChecksSerialize() async {
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let playingWithoutTarget = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let ambiguousWithLaggingAudioOutput = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let releaseGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            playingWithoutTarget,
            ambiguousWithLaggingAudioOutput,
            ambiguousWithLaggingAudioOutput,
            confirmedSilentSnapshotWithoutTarget,
        ]
    )
    driver.snapshotGates[4] = releaseGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected pending custody for the first capture.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { releaseGate.waitCount == 1 }
    guard let secondToken = await service.beginInterruption() else {
        Issue.record("Expected the rapid restart token.")
        releaseGate.open()
        await firstEnd.value
        return
    }

    await service.endInterruption(token: secondToken)
    #expect(driver.snapshotCallCount == 4)
    releaseGate.open()
    await firstEnd.value

    #expect(driver.snapshotCallCount == 4)
    #expect(driver.commands == [.pause, .pause, .play])
}

@MainActor
@Test("Rapid restart re-pauses pending media that becomes active at release")
func rapidRestartRepausesPendingMediaThatBecomesActive() async {
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let playingWithoutTarget = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let ambiguousWithLaggingAudioOutput = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let releaseGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            playingWithoutTarget,
            ambiguousWithLaggingAudioOutput,
            ambiguousWithLaggingAudioOutput,
            playingWithoutTarget,
            confirmedSilentSnapshotWithoutTarget,
        ]
    )
    driver.snapshotGates[4] = releaseGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected pending custody for the first capture.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { releaseGate.waitCount == 1 }
    let secondToken = await service.beginInterruption()
    releaseGate.open()
    await firstEnd.value

    guard let secondToken else {
        Issue.record("Expected the new capture to inherit app-scoped custody.")
        return
    }
    #expect(driver.commands == [.pause, .pause, .pause])

    await service.endInterruption(token: secondToken)
    #expect(driver.commands == [.pause, .pause, .pause, .play])
}

@MainActor
@Test("Rapid restart rejects an active same-bundle replacement before re-Pause")
func rapidRestartRejectsActiveReplacementBeforePendingRePause() async {
    let playingWithoutTarget = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let pausedTransitionWithLaggingOutput = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let replacementOutput = MediaAudioOutputTarget(
        processID: primaryAudioOutput.processID + 1,
        applicationBundleIdentifier: primaryAudioOutput.applicationBundleIdentifier
    )
    let activeReplacement = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [replacementOutput]
    )
    let releaseGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            playingWithoutTarget,
            pausedTransitionWithLaggingOutput,
            pausedTransitionWithLaggingOutput,
            activeReplacement,
        ]
    )
    driver.snapshotGates[4] = releaseGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected pending custody for the original exact process.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { releaseGate.waitCount == 1 }
    guard let secondToken = await service.beginInterruption() else {
        Issue.record("Expected the rapid restart to join the pending interruption.")
        releaseGate.open()
        await firstEnd.value
        return
    }

    releaseGate.open()
    await firstEnd.value

    #expect(
        driver.commands == [.pause, .pause],
        "A replacement process must be rejected before any lineage-derived Pause is sent."
    )
    await service.endInterruption(token: secondToken)
    #expect(!driver.commands.contains(.play))
}

@MainActor
@Test("Pending re-Pause preserves exact custody when unrelated output is also active")
func pendingRePauseIgnoresUnrelatedActiveOutput() async {
    let unrelatedOutput = MediaAudioOutputTarget(
        processID: 84,
        applicationBundleIdentifier: "com.example.unrelated"
    )
    let playingWithoutTarget = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let pausedTransitionWithLaggingOutput = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let originalAndUnrelatedAreActive = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [primaryAudioOutput, unrelatedOutput]
    )
    let onlyUnrelatedRemainsActive = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [unrelatedOutput]
    )
    let releaseGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            playingWithoutTarget,
            pausedTransitionWithLaggingOutput,
            pausedTransitionWithLaggingOutput,
            originalAndUnrelatedAreActive,
            onlyUnrelatedRemainsActive,
        ]
    )
    driver.snapshotGates[4] = releaseGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected pending custody for the original exact process.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { releaseGate.waitCount == 1 }
    guard let secondToken = await service.beginInterruption() else {
        Issue.record("Expected the rapid restart to join pending custody.")
        releaseGate.open()
        await firstEnd.value
        return
    }
    releaseGate.open()
    await firstEnd.value

    #expect(driver.commands == [.pause, .pause, .pause])
    await service.endInterruption(token: secondToken)
    #expect(driver.commands == [.pause, .pause, .pause, .play])
    #expect(
        driver.destinations.allSatisfy {
            $0 == .observedApplications(["com.example.player"])
        }
    )
}

@MainActor
@Test("Ending rapid restart during pending re-Pause finalizes exactly once")
func endingRapidRestartDuringPendingRePauseFinalizesExactlyOnce() async {
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let playingWithoutTarget = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let ambiguousWithLaggingAudioOutput = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let releaseGate = MediaSnapshotGate()
    let repauseGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            playingWithoutTarget,
            ambiguousWithLaggingAudioOutput,
            ambiguousWithLaggingAudioOutput,
            playingWithoutTarget,
            confirmedSilentSnapshotWithoutTarget,
        ]
    )
    driver.snapshotGates[4] = releaseGate
    driver.sendGates[3] = repauseGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected pending custody for the first capture.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { releaseGate.waitCount == 1 }
    guard let secondToken = await service.beginInterruption() else {
        Issue.record("Expected the rapid restart token.")
        releaseGate.open()
        await firstEnd.value
        return
    }

    releaseGate.open()
    await waitUntil { repauseGate.waitCount == 1 }
    await service.endInterruption(token: secondToken)
    repauseGate.open()
    await firstEnd.value

    #expect(driver.commands == [.pause, .pause, .pause, .play])
    #expect(driver.snapshotCallCount == 5)
}

@MainActor
@Test("Pending owner release restores only after release proves silence")
func pendingOwnerReleaseRestoresOnlyAfterReleaseProof() async {
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let playingWithoutTarget = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let ambiguousWithLaggingAudioOutput = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let verificationGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            playingWithoutTarget,
            ambiguousWithLaggingAudioOutput,
            confirmedSilentSnapshotWithoutTarget,
        ]
    )
    driver.snapshotGates[2] = verificationGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )

    let completion = CompletionProbe()
    let begin = Task { @MainActor in
        let token = await service.beginInterruption()
        completion.didComplete = true
        return token
    }
    await waitUntil { verificationGate.waitCount == 1 }
    await waitUntil { completion.didComplete }
    guard completion.didComplete, let token = await begin.value else {
        verificationGate.open()
        _ = await begin.value
        Issue.record("Pending custody should be returned before verification completes.")
        return
    }

    let release = Task { @MainActor in
        await service.endInterruption(token: token)
    }
    await Task.yield()
    #expect(driver.commands == [.pause])
    verificationGate.open()
    await release.value
    await waitUntil { driver.commands == [.pause, .play] }
    #expect(driver.commands == [.pause, .play])
}

@MainActor
@Test("Unknown playback with active output takes pending custody without an early Play")
func unknownPlaybackBeforePauseNeverCreatesResumeOwnership() async {
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let unknownWithLaggingAudioOutput = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [unknownWithLaggingAudioOutput, unknownWithLaggingAudioOutput]
    )
    let service = makeService(driver: driver)

    let token = await service.beginInterruption()

    #expect(token != nil)
    #expect(driver.commands == [.pause])
    #expect(!driver.commands.contains(.play))
}

@MainActor
@Test("Unknown playback before capture pauses the exact observed application")
func unknownPlaybackBeforeCaptureNeverSendsMediaCommand() async {
    let unknownWithExactAudioOutput = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [unknownWithExactAudioOutput]
    )
    let service = makeService(driver: driver)

    let token = await service.beginInterruption()

    #expect(token != nil)
    #expect(driver.destinations == [.observedApplications(["com.example.player"])])
    #expect(!driver.commands.contains(.play))
}

@MainActor
@Test("Failed semantic Pause creates no token")
func failedSemanticPauseCreatesNoToken() async {
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot],
        sendResults: [false]
    )
    let service = makeService(driver: driver)

    let token = await service.beginInterruption()

    #expect(token == nil)
    #expect(driver.commands == [.pause])
}

@MainActor
@Test("Ending a verified interruption resumes only the originally observed app")
func endingVerifiedInterruptionResumesOriginalObservedApp() async {
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, confirmedPausedSnapshot, confirmedPausedSnapshot]
    )
    let service = makeService(driver: driver)
    guard let token = await service.beginInterruption() else {
        Issue.record("Expected interruption token for verified playback.")
        return
    }

    await service.endInterruption(token: token)

    #expect(driver.commands == [.pause, .play])
    #expect(
        driver.destinations == [
            .observedApplications(["com.example.player"]),
            .observedApplications(["com.example.player"]),
        ]
    )
}

@MainActor
@Test("Nested tokens resume exactly once when the last owner ends")
func nestedTokensResumeExactlyOnceWhenLastOwnerEnds() async {
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, confirmedPausedSnapshot]
    )
    let service = makeService(driver: driver)
    guard let firstToken = await service.beginInterruption(),
          let secondToken = await service.beginInterruption()
    else {
        Issue.record("Expected both interruption tokens.")
        return
    }

    await service.endInterruption(token: firstToken)
    #expect(driver.commands == [.pause])

    await service.endInterruption(token: secondToken)
    #expect(driver.commands == [.pause, .play])

    await service.endInterruption(token: secondToken)
    #expect(driver.commands == [.pause, .play])
}

@MainActor
@Test("A second begin joins an in-flight Pause transition")
func concurrentBeginJoinsPauseTransition() async {
    let verificationGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, confirmedPausedSnapshot, confirmedPausedSnapshot]
    )
    driver.snapshotGates[2] = verificationGate
    let service = makeService(driver: driver)

    let firstBegin = Task { @MainActor in await service.beginInterruption() }
    await waitUntil { verificationGate.waitCount == 1 }

    let secondBegin = Task { @MainActor in await service.beginInterruption() }
    await Task.yield()
    verificationGate.open()

    guard let firstToken = await firstBegin.value,
          let secondToken = await secondBegin.value
    else {
        Issue.record("Both callers should own the verified interruption.")
        return
    }

    #expect(driver.commands == [.pause])
    await service.endInterruption(token: firstToken)
    #expect(driver.commands == [.pause])
    await service.endInterruption(token: secondToken)
    #expect(driver.commands == [.pause, .play])
}

@MainActor
@Test("Releasing custody after Pause restores verified media exactly once")
func releasedVerifiedPauseRestoresMediaExactlyOnce() async {
    let verificationGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, confirmedPausedSnapshot]
    )
    driver.snapshotGates[2] = verificationGate
    let service = makeService(driver: driver)

    let completion = CompletionProbe()
    let begin = Task { @MainActor in
        let token = await service.beginInterruption()
        completion.didComplete = true
        return token
    }
    await waitUntil { verificationGate.waitCount == 1 }
    #expect(driver.commands == [.pause])
    await waitUntil { completion.didComplete }
    guard completion.didComplete, let token = await begin.value else {
        verificationGate.open()
        _ = await begin.value
        Issue.record("Verified custody should be returned before verification completes.")
        return
    }

    let release = Task { @MainActor in
        await service.endInterruption(token: token)
    }
    await Task.yield()
    #expect(driver.commands == [.pause])
    verificationGate.open()

    await release.value
    await waitUntil { driver.commands == [.pause, .play] }
    #expect(driver.commands == [.pause, .play])
}

@MainActor
@Test("Releasing custody waits for a delayed accepted Pause effect and restores once")
func releasedAcceptedPauseWithDelayedEffectRestoresMediaOnce() async {
    let laggingPausedSnapshot = makeSnapshot(
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let firstVerificationGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPlayingSnapshot,
            laggingPausedSnapshot,
            laggingPausedSnapshot,
            confirmedPausedSnapshot,
        ]
    )
    driver.snapshotGates[2] = firstVerificationGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0, 0]
    )

    let completion = CompletionProbe()
    let begin = Task { @MainActor in
        let token = await service.beginInterruption()
        completion.didComplete = true
        return token
    }
    await waitUntil { firstVerificationGate.waitCount == 1 }
    #expect(driver.commands == [.pause])
    await waitUntil { completion.didComplete }
    guard completion.didComplete, let token = await begin.value else {
        firstVerificationGate.open()
        _ = await begin.value
        Issue.record("Pending custody should be returned before delayed verification completes.")
        return
    }

    let release = Task { @MainActor in
        await service.endInterruption(token: token)
    }
    await Task.yield()
    #expect(!driver.commands.contains(.play))
    firstVerificationGate.open()

    await release.value
    await waitUntil { driver.commands.last == .play }
    #expect(driver.commands.filter { $0 == .play }.count == 1)
    #expect(driver.commands.last == .play)
    #expect(driver.verifiedDestinations.last?.expectedProcessTargets == [primaryAudioOutput])
}

@MainActor
@Test("Release preserves the accepted-Pause settling window")
func releasePreservesAcceptedPauseSettlingWindow() async {
    let sleepGate = MediaSleepGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [80_000_000, 120_000_000],
        sleep: { _ in
            await sleepGate.wait()
        }
    )

    let beginProbe = CompletionProbe()
    let begin = Task { @MainActor in
        let token = await service.beginInterruption()
        beginProbe.didComplete = true
        return token
    }
    let reachedFirstSleep = await sleepGate.waitUntilCount(
        1,
        timeoutMilliseconds: 1_000
    )
    let beginCompleted = await waitUntilSatisfied { beginProbe.didComplete }
    guard reachedFirstSleep, beginCompleted else {
        begin.cancel()
        await sleepGate.openPermanently()
        if let token = await begin.value {
            await service.endInterruption(token: token)
        }
        Issue.record(
            "Initial custody and the first verification sleep must both become observable."
        )
        return
    }
    guard let token = await begin.value else {
        await sleepGate.openPermanently()
        Issue.record("An accepted Pause should publish custody before verification completes.")
        return
    }

    let releaseProbe = CompletionProbe()
    let release = Task { @MainActor in
        releaseProbe.didStart = true
        await service.endInterruption(token: token)
        releaseProbe.didComplete = true
    }
    await waitUntil { releaseProbe.didStart }

    #expect(!releaseProbe.didComplete)
    #expect(driver.commands == [.pause])

    await sleepGate.open()
    let reachedSecondSleep = await sleepGate.waitUntilCount(
        2,
        timeoutMilliseconds: 1_000
    )
    #expect(
        reachedSecondSleep,
        "Release must preserve every remaining verification delay before adjudicating custody."
    )
    guard reachedSecondSleep else {
        await sleepGate.openPermanently()
        await release.value
        return
    }

    #expect(!releaseProbe.didComplete)
    #expect(driver.commands == [.pause])
    await sleepGate.open()

    await release.value
    #expect(releaseProbe.didComplete)
    #expect(driver.commands == [.pause, .play])
    #expect(driver.commands.filter { $0 == .pause }.count == 1)
    #expect(driver.commands.filter { $0 == .play }.count == 1)
    #expect(driver.verifiedDestinations.last?.expectedProcessTargets == [primaryAudioOutput])
}

@MainActor
@Test("A new owner restores Pause retries during release drain")
func newOwnerRestoresPauseRetriesDuringReleaseDrain() async {
    let sleepGate = MediaSleepGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [80_000_000, 120_000_000],
        sleep: { _ in
            await sleepGate.wait()
        }
    )

    let beginProbe = CompletionProbe()
    let begin = Task { @MainActor in
        let token = await service.beginInterruption()
        beginProbe.didComplete = true
        return token
    }
    let reachedFirstSleep = await sleepGate.waitUntilCount(
        1,
        timeoutMilliseconds: 1_000
    )
    let beginCompleted = await waitUntilSatisfied { beginProbe.didComplete }
    guard reachedFirstSleep, beginCompleted else {
        begin.cancel()
        await sleepGate.openPermanently()
        if let token = await begin.value {
            await service.endInterruption(token: token)
        }
        Issue.record(
            "Initial custody and the first verification sleep must both become observable."
        )
        return
    }
    guard let firstToken = await begin.value else {
        await sleepGate.openPermanently()
        Issue.record("Expected initial pending custody.")
        return
    }

    let firstReleaseProbe = CompletionProbe()
    let firstRelease = Task { @MainActor in
        firstReleaseProbe.didStart = true
        await service.endInterruption(token: firstToken)
        firstReleaseProbe.didComplete = true
    }
    await waitUntil { firstReleaseProbe.didStart }

    guard let secondToken = await service.beginInterruption() else {
        await sleepGate.openPermanently()
        await firstRelease.value
        Issue.record("A new capture should inherit pending custody during release drain.")
        return
    }

    await sleepGate.open()
    let reachedSecondSleep = await sleepGate.waitUntilCount(
        2,
        timeoutMilliseconds: 1_000
    )
    #expect(
        reachedSecondSleep,
        "The release drain should preserve the second configured verification delay."
    )
    guard reachedSecondSleep else {
        await sleepGate.openPermanently()
        await firstRelease.value
        await service.endInterruption(token: secondToken)
        return
    }

    #expect(!firstReleaseProbe.didComplete)
    #expect(
        driver.commands == [.pause, .pause],
        "Once a new owner joins, strong same-lineage playback should authorize a targeted retry Pause."
    )
    await sleepGate.open()

    await firstRelease.value
    #expect(firstReleaseProbe.didComplete)
    #expect(driver.commands == [.pause, .pause])

    await service.endInterruption(token: secondToken)
    #expect(driver.commands == [.pause, .pause, .play])
    #expect(driver.verifiedDestinations.last?.expectedProcessTargets == [primaryAudioOutput])
}

@MainActor
@Test("Cancellation during the accepted-Pause delay cannot bypass verification")
func cancellationDuringAcceptedPauseDelayWaitsForVerification() async {
    let sleepGate = MediaSleepGate()
    let pauseDispatchGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, confirmedPausedSnapshot]
    )
    driver.sendGates[1] = pauseDispatchGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [80_000_000],
        sleep: { _ in
            await sleepGate.wait()
        }
    )

    let begin = Task { @MainActor in
        await service.beginInterruption()
    }
    // Cancel while the Pause dispatch is still in flight, before custody has
    // been published and the token handed back.
    let reachedPauseDispatch = await waitUntilSatisfied {
        pauseDispatchGate.waitCount == 1
    }
    guard reachedPauseDispatch else {
        begin.cancel()
        pauseDispatchGate.openPermanently()
        await sleepGate.openPermanently()
        _ = await begin.value
        Issue.record("Cancellation must rendezvous with the in-flight Pause dispatch.")
        return
    }
    begin.cancel()
    await Task.yield()
    pauseDispatchGate.openPermanently()

    // The cancelled transition still pays its full verification delay before
    // any restoring command can be considered.
    let reachedVerificationSleep = await sleepGate.waitUntilCount(
        1,
        timeoutMilliseconds: 1_000
    )
    guard reachedVerificationSleep else {
        pauseDispatchGate.openPermanently()
        await sleepGate.openPermanently()
        _ = await begin.value
        Issue.record("Cancellation must enter the accepted-Pause verification delay.")
        return
    }
    #expect(driver.commands == [.pause])
    await sleepGate.open()

    #expect(await begin.value == nil)
    await waitUntil { driver.commands == [.pause, .play] }
    #expect(driver.commands == [.pause, .play])
}

@MainActor
@Test("A new begin re-pauses an in-flight resume and inherits verified ownership")
func newBeginRepauseInFlightResumeAndInheritsOwnership() async {
    let resumeGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
        ]
    )
    driver.sendGates[2] = resumeGate
    let service = makeService(driver: driver)
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected the first interruption token.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { resumeGate.waitCount == 1 }
    #expect(driver.commands == [.pause, .play])

    let completion = CompletionProbe()
    let secondBegin = Task { @MainActor in
        completion.didStart = true
        let token = await service.beginInterruption()
        completion.didComplete = true
        return token
    }
    await waitUntil { completion.didStart }
    await Task.yield()

    #expect(!completion.didComplete)
    #expect(driver.snapshotCallCount == 2)

    resumeGate.open()
    await firstEnd.value
    guard let secondToken = await secondBegin.value else {
        Issue.record("Expected a fresh interruption after resume completed.")
        return
    }

    #expect(driver.commands == [.pause, .play, .pause])
    await service.endInterruption(token: secondToken)
    #expect(driver.commands == [.pause, .play, .pause, .play])
}

@MainActor
@Test("In-flight re-Pause keeps original ownership when another app is playing")
func inFlightRePauseKeepsOwnershipWithUnrelatedPlayback() async {
    let unrelatedTarget = MediaPlaybackTarget(
        processID: 77,
        bundleIdentifier: "com.example.other"
    )
    let unrelatedOutput = MediaAudioOutputTarget(
        processID: unrelatedTarget.processID,
        applicationBundleIdentifier: unrelatedTarget.bundleIdentifier
    )
    let originalAndUnrelatedPlaying = makeSnapshot(
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [primaryAudioOutput, unrelatedOutput]
    )
    let onlyUnrelatedPlaying = makeSnapshot(
        target: unrelatedTarget,
        contentIdentifier: "other-item",
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [unrelatedOutput]
    )
    let initialPlayGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            originalAndUnrelatedPlaying,
            onlyUnrelatedPlaying,
        ]
    )
    driver.sendGates[2] = initialPlayGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected the original verified interruption.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { initialPlayGate.waitCount == 1 }
    let secondBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    initialPlayGate.open()
    await firstEnd.value

    guard let secondToken = await secondBegin.value else {
        Issue.record("Expected the new capture to retain the original app's exact custody.")
        return
    }
    #expect(driver.commands == [.pause, .play, .pause])

    await service.endInterruption(token: secondToken)
    #expect(driver.commands == [.pause, .play, .pause, .play])
    #expect(
        driver.destinations.last
            == .observedApplications([primaryTarget.bundleIdentifier])
    )
}

@MainActor
@Test("A new begin inherits paused ownership when resume is cancelled before Play")
func newBeginInheritsOwnershipWhenResumeIsCancelledBeforePlay() async {
    let resumeStartGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, confirmedPausedSnapshot]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        beforeInitialResumeDispatch: {
            if resumeStartGate.waitCount == 0 {
                await resumeStartGate.wait()
            }
        }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected the first verified interruption.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { resumeStartGate.waitCount == 1 }
    let secondBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    await Task.yield()
    resumeStartGate.open()
    await firstEnd.value

    guard let secondToken = await secondBegin.value else {
        Issue.record("The new capture must inherit the still-paused media receipt.")
        return
    }
    #expect(driver.commands == [.pause])

    await service.endInterruption(token: secondToken)
    #expect(driver.commands == [.pause, .play])
}

@MainActor
@Test("A cancelled pre-Play join cannot strand the original paused media")
func cancelledPrePlayJoinStillResumesOriginalMedia() async {
    let resumeStartGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, confirmedPausedSnapshot]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        beforeInitialResumeDispatch: {
            if resumeStartGate.waitCount == 0 {
                await resumeStartGate.wait()
            }
        }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected the first verified interruption.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { resumeStartGate.waitCount == 1 }
    let cancelledJoin = Task { @MainActor in
        await service.beginInterruption()
    }
    await Task.yield()
    cancelledJoin.cancel()
    resumeStartGate.open()

    #expect(await cancelledJoin.value == nil)
    await firstEnd.value
    #expect(driver.commands == [.pause, .play])
}

@MainActor
@Test("A cancelled owner after accepted re-Pause restores the original media")
func cancelledOwnerAfterAcceptedRePauseRestoresOriginalMedia() async {
    let ambiguousExactOutput = makeSnapshot(
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let initialPlayGate = MediaSnapshotGate()
    let rePauseGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
            ambiguousExactOutput,
        ]
    )
    driver.sendGates[2] = initialPlayGate
    driver.sendGates[3] = rePauseGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected the original verified interruption.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { initialPlayGate.waitCount == 1 }
    let cancelledOwner = Task { @MainActor in
        await service.beginInterruption()
    }
    initialPlayGate.open()
    await waitUntil { rePauseGate.waitCount == 1 }

    cancelledOwner.cancel()
    rePauseGate.open()

    #expect(await cancelledOwner.value == nil)
    await firstEnd.value
    #expect(driver.commands == [.pause, .play, .pause, .play])
}

@MainActor
@Test("In-flight resume re-Pause retains exact custody while Core Audio lags")
func inFlightResumeRePauseRetainsCustodyAcrossLaggingOutput() async {
    let laggingPausedSnapshot = makeSnapshot(
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let resumeGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
            laggingPausedSnapshot,
            confirmedPausedSnapshot,
        ]
    )
    driver.sendGates[2] = resumeGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected the first verified interruption.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { resumeGate.waitCount == 1 }
    let secondBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    await Task.yield()
    resumeGate.open()
    await firstEnd.value

    guard let secondToken = await secondBegin.value else {
        Issue.record("Accepted exact-process re-Pause should retain the new capture's custody.")
        return
    }
    #expect(driver.commands == [.pause, .play, .pause, .pause])

    await service.endInterruption(token: secondToken)
    #expect(driver.commands == [.pause, .play, .pause, .pause, .play])
}

@MainActor
@Test("In-flight resume rejects a same-bundle replacement before re-Pause")
func inFlightResumeRejectsReplacementBeforeRePause() async {
    let replacementTarget = MediaPlaybackTarget(
        processID: primaryTarget.processID + 1,
        bundleIdentifier: primaryTarget.bundleIdentifier
    )
    let replacementOutput = MediaAudioOutputTarget(
        processID: primaryAudioOutput.processID + 1,
        applicationBundleIdentifier: primaryAudioOutput.applicationBundleIdentifier
    )
    let activeReplacement = makeSnapshot(
        target: replacementTarget,
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [replacementOutput]
    )
    let unknownReplacement = makeSnapshot(
        target: replacementTarget,
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: [replacementOutput]
    )
    let resumeGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            activeReplacement,
            unknownReplacement,
        ]
    )
    driver.sendGates[2] = resumeGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected the first verified interruption.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { resumeGate.waitCount == 1 }
    let secondBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    await Task.yield()
    resumeGate.open()
    await firstEnd.value

    guard let secondToken = await secondBegin.value else {
        Issue.record("A fresh snapshot showing active output should start a new interruption.")
        return
    }
    #expect(
        driver.commands == [.pause, .play, .pause],
        "Stale in-flight lineage must not emit a lineage command for a replacement process."
    )

    await service.endInterruption(token: secondToken)

    #expect(
        driver.verifiedDestinations.last?.expectedProcessTargets == [replacementOutput],
        "Ownership must bind the freshly observed process, never the replaced one."
    )
}

@MainActor
@Test("In-flight resume does not re-Pause an exact process already reported stopped")
func inFlightResumeRejectsAlreadyStoppedRePausePreflight() async {
    let alreadyStoppedWithLaggingOutput = makeSnapshot(
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let resumeGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            alreadyStoppedWithLaggingOutput,
        ]
    )
    driver.sendGates[2] = resumeGate
    let service = makeService(driver: driver)
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected the first verified interruption.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { resumeGate.waitCount == 1 }
    let secondBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    await Task.yield()
    resumeGate.open()
    await firstEnd.value

    #expect(await secondBegin.value == nil)
    #expect(driver.commands == [.pause, .play])
}

@MainActor
@Test("In-flight resume never retries re-Pause after a same-bundle process replacement")
func inFlightResumeDoesNotRetryRePauseAfterProcessReplacement() async {
    let unavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let replacementTarget = MediaPlaybackTarget(
        processID: primaryTarget.processID + 1,
        bundleIdentifier: primaryTarget.bundleIdentifier
    )
    let replacementOutput = MediaAudioOutputTarget(
        processID: primaryAudioOutput.processID + 1,
        applicationBundleIdentifier: primaryAudioOutput.applicationBundleIdentifier
    )
    let activeReplacement = makeSnapshot(
        target: replacementTarget,
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [replacementOutput]
    )
    let resumeGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
            activeReplacement,
            activeReplacement,
            unavailable,
        ]
    )
    driver.sendGates[2] = resumeGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected the first verified interruption.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { resumeGate.waitCount == 1 }
    let secondBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    await Task.yield()
    resumeGate.open()
    await firstEnd.value

    #expect(await secondBegin.value == nil)
    #expect(driver.commands == [.pause, .play, .pause])
}

@MainActor
@Test("In-flight resume retains pending custody across partial observation loss")
func inFlightResumeRetainsPendingCustodyAcrossPartialObservationLoss() async {
    let unavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let resumeGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
            unavailable,
            unavailable,
        ]
    )
    driver.sendGates[2] = resumeGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected the first verified interruption.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { resumeGate.waitCount == 1 }
    let secondBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    await Task.yield()
    resumeGate.open()
    await firstEnd.value

    #expect(await secondBegin.value != nil)
    #expect(driver.commands.filter { $0 == .play }.count == 1)
}

@MainActor
@Test("Accepted in-flight re-Pause remains pending until capture release proves silence")
func inFlightResumeDefersPlayUntilReleaseProof() async {
    let unavailable = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let resumeGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
            unavailable,
            unavailable,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
        ]
    )
    driver.sendGates[2] = resumeGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0],
        resumeVerificationDelays: [0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected the first verified interruption.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { resumeGate.waitCount == 1 }
    let secondBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    await Task.yield()
    resumeGate.open()
    await firstEnd.value

    guard let secondToken = await secondBegin.value else {
        Issue.record("Accepted exact-lineage re-Pause should retain pending custody.")
        return
    }
    #expect(driver.commands == [.pause, .play, .pause])

    await service.endInterruption(token: secondToken)

    #expect(driver.commands == [.pause, .play, .pause, .play])
}

@MainActor
@Test("Partially unavailable in-flight re-Pause remains pending until release proof")
func inFlightResumeDefersPlayAcrossPartialUnavailableEvidence() async {
    let partialUnavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let resumeGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
            partialUnavailable,
            partialUnavailable,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
        ]
    )
    driver.sendGates[2] = resumeGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0],
        resumeVerificationDelays: [0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected the first verified interruption.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { resumeGate.waitCount == 1 }
    let secondBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    await Task.yield()
    resumeGate.open()
    await firstEnd.value

    guard let secondToken = await secondBegin.value else {
        Issue.record("Partial observation loss must retain pending exact-lineage custody.")
        return
    }
    #expect(driver.commands == [.pause, .play, .pause])

    await service.endInterruption(token: secondToken)

    #expect(driver.commands == [.pause, .play, .pause, .play])
}

@MainActor
@Test("An unresolved re-Pause cannot Play under a rapid-restart owner")
func unresolvedRepauseCannotPlayUnderRapidRestartOwner() async {
    let unresolvedSnapshot = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let resumeGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
            unresolvedSnapshot,
            confirmedPlayingSnapshot,
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
        ]
    )
    driver.sendGates[2] = resumeGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected the first interruption token.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { resumeGate.waitCount == 1 }

    let secondBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    await Task.yield()
    resumeGate.open()
    await firstEnd.value

    guard let secondToken = await secondBegin.value else {
        Issue.record("A fresh verified Pause should recover ownership after the unresolved re-Pause.")
        return
    }
    #expect(driver.commands == [.pause, .play, .pause, .pause, .pause])
    #expect(driver.commands.dropFirst(2).allSatisfy { $0 == .pause })

    await service.endInterruption(token: secondToken)

    #expect(driver.commands == [.pause, .play, .pause, .pause, .pause, .play])
}

@MainActor
@Test("Rejected persistent re-Pause cannot retain resume ownership")
func rejectedPersistentRepauseCannotRetainResumeOwnership() async {
    let resumeGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
            confirmedPlayingSnapshot,
            confirmedPlayingSnapshot,
        ]
    )
    driver.acceptedApplicationsBySend = [
        ["com.example.player"],
        ["com.example.player"],
        [],
        [],
        [],
    ]
    driver.sendGates[2] = resumeGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected the first interruption token.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { resumeGate.waitCount == 1 }

    let secondBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    await Task.yield()
    resumeGate.open()
    await firstEnd.value

    let secondToken = await secondBegin.value
    #expect(secondToken == nil, "An active app whose re-Pause was rejected must not be treated as paused.")
    #expect(
        driver.commands.dropFirst(2).allSatisfy { $0 == .pause },
        "A failed re-Pause must not manufacture ownership and later send another Play."
    )
    if let secondToken {
        await service.endInterruption(token: secondToken)
    }
}

@MainActor
@Test("Rejected re-Pause plus silent output cannot retain resume ownership")
func rejectedSilentRepauseCannotRetainResumeOwnership() async {
    let resumeGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
        ]
    )
    driver.acceptedApplicationsBySend = [
        ["com.example.player"],
        ["com.example.player"],
        [],
    ]
    driver.sendGates[2] = resumeGate
    let service = makeService(driver: driver)
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected the first interruption token.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { resumeGate.waitCount == 1 }
    let secondBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    await Task.yield()
    resumeGate.open()
    await firstEnd.value

    let secondToken = await secondBegin.value
    #expect(secondToken == nil)
    #expect(driver.commands == [.pause, .play, .pause])
    if let secondToken {
        await service.endInterruption(token: secondToken)
    }
}

@MainActor
@Test("In-flight resume ownership narrows to applications that accepted re-Pause")
func inFlightResumeOwnershipNarrowsToAcceptedRepauseApplications() async {
    let secondaryAudioOutput = MediaAudioOutputTarget(
        processID: 84,
        applicationBundleIdentifier: "com.example.secondary"
    )
    let bothPlaying = makeSnapshot(
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [primaryAudioOutput, secondaryAudioOutput]
    )
    let resumeGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            bothPlaying,
            confirmedPausedSnapshot,
            bothPlaying,
            confirmedPausedSnapshot,
        ]
    )
    driver.acceptedApplicationsBySend = [
        ["com.example.player", "com.example.secondary"],
        ["com.example.player", "com.example.secondary"],
        ["com.example.player"],
        ["com.example.player"],
    ]
    driver.sendGates[2] = resumeGate
    let service = makeService(driver: driver)
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected interruption ownership for both applications.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { resumeGate.waitCount == 1 }
    let secondBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    await Task.yield()
    resumeGate.open()
    await firstEnd.value

    guard let secondToken = await secondBegin.value else {
        Issue.record("Expected ownership for the exact accepted re-Pause subset.")
        return
    }
    await service.endInterruption(token: secondToken)

    #expect(driver.commands == [.pause, .play, .pause, .play])
    #expect(
        driver.destinations == [
            .observedApplications(["com.example.player", "com.example.secondary"]),
            .observedApplications(["com.example.player", "com.example.secondary"]),
            .observedApplications(["com.example.player", "com.example.secondary"]),
            .observedApplications(["com.example.player"]),
        ]
    )
}

@MainActor
@Test("A begin joining the final Play retry retains only verified re-Pause ownership")
func beginJoiningFinalPlayRetryRetainsVerifiedOwnership() async {
    let finalRetryGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            confirmedPausedSnapshot,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
        ]
    )
    driver.sendGates[3] = finalRetryGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        resumeVerificationDelays: [0, 0]
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected the first interruption token.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { finalRetryGate.waitCount == 1 }
    #expect(driver.commands == [.pause, .play, .play])

    let secondBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    await Task.yield()
    finalRetryGate.open()
    await firstEnd.value

    guard let secondToken = await secondBegin.value else {
        Issue.record("The joining begin should inherit the receipt after verified re-Pause.")
        return
    }
    #expect(driver.commands == [.pause, .play, .play, .pause])

    await service.endInterruption(token: secondToken)
    #expect(driver.commands == [.pause, .play, .play, .pause, .play])
    #expect(
        driver.destinations.allSatisfy {
            $0 == .observedApplications(["com.example.player"])
        }
    )
}

@MainActor
@Test("Targeted Play retries while a verified-paused app remains silent")
func targetedPlayRetriesUntilVerifiedApplicationResumes() async {
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        resumeVerificationDelays: [0, 0]
    )
    guard let token = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }

    await service.endInterruption(token: token)

    #expect(driver.commands == [.pause, .play, .play])
    #expect(
        driver.destinations == Array(
            repeating: .observedApplications(["com.example.player"]),
            count: 3
        )
    )
}

@MainActor
@Test("Exact strong playback evidence prevents a duplicate Play while Core Audio lags")
func exactStrongPlaybackEvidencePreventsDuplicatePlay() async {
    let playingWithLaggingCoreAudio = makeSnapshot(
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: []
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            playingWithLaggingCoreAudio,
            playingWithLaggingCoreAudio,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        resumeVerificationDelays: [0, 0]
    )
    guard let token = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }

    await service.endInterruption(token: token)

    #expect(driver.commands == [.pause, .play])
}

@MainActor
@Test("Targeted Play never retries after a same-bundle target replacement")
func targetedPlayDoesNotRetryAfterSameBundleTargetReplacement() async {
    let replacementTarget = MediaPlaybackTarget(
        processID: primaryTarget.processID + 1,
        bundleIdentifier: primaryTarget.bundleIdentifier
    )
    let silentReplacement = makeSnapshot(
        target: replacementTarget,
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: []
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            silentReplacement,
            silentReplacement,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        resumeVerificationDelays: [0, 0]
    )
    guard let token = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }

    await service.endInterruption(token: token)

    #expect(driver.commands == [.pause, .play])
}

@MainActor
@Test("Rejected targeted Play retries only the verified-paused app")
func rejectedTargetedPlayRetriesExactVerifiedApplication() async {
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
        ]
    )
    driver.acceptedApplicationsBySend = [
        ["com.example.player"],
        [],
        ["com.example.player"],
    ]
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        resumeVerificationDelays: [0, 0]
    )
    guard let token = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }

    await service.endInterruption(token: token)

    #expect(driver.commands == [.pause, .play, .play])
    #expect(
        driver.destinations.allSatisfy {
            $0 == .observedApplications(["com.example.player"])
        }
    )
}

@MainActor
@Test("A delayed accepted Play remains the final command after bounded verification")
func delayedAcceptedPlayRemainsFinalCommandAfterBoundedVerification() async {
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            confirmedPausedSnapshot,
            confirmedPausedSnapshot,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        resumeVerificationDelays: [0, 0]
    )
    guard let token = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }

    await service.endInterruption(token: token)

    #expect(driver.commands == [.pause, .play, .play])
    #expect(
        driver.destinations.allSatisfy {
            $0 == .observedApplications(["com.example.player"])
        }
    )
}

@MainActor
@Test("Unavailable resume observation leaves exact targeted Play as the final command")
func unavailableResumeObservationLeavesTargetedPlayFinal() async {
    let unavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            unavailable,
            unavailable,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        resumeVerificationDelays: [0, 0]
    )
    guard let token = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }

    await service.endInterruption(token: token)

    #expect(driver.commands == [.pause, .play, .play])
    #expect(driver.commands.last == .play)
    #expect(driver.destinations.last == .observedApplications(["com.example.player"]))
}

@MainActor
@Test("Immediate begin consumes bounded unavailable-resume lineage")
func immediateBeginConsumesBoundedUnavailableResumeLineage() async {
    let unavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            unavailable,
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        resumeVerificationDelays: [0],
        resumeLineageGraceDuration: 3,
        now: { 100 }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }
    await service.endInterruption(token: firstToken)
    #expect(driver.commands == [.pause, .play])

    guard let secondToken = await service.beginInterruption() else {
        Issue.record("Accepted exact-app Pause should continue the bounded original receipt.")
        return
    }
    #expect(driver.commands == [.pause, .play, .pause])

    await service.endInterruption(token: secondToken)
    #expect(driver.commands == [.pause, .play, .pause, .play])
}

@MainActor
@Test("Bounded resume-lineage re-Pause retains exact custody while Core Audio lags")
func boundedResumeLineageRePauseRetainsCustodyAcrossLaggingOutput() async {
    let unavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let laggingPausedSnapshot = makeSnapshot(
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            unavailable,
            confirmedPlayingSnapshot,
            laggingPausedSnapshot,
            confirmedPausedSnapshot,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0],
        resumeVerificationDelays: [0],
        resumeLineageGraceDuration: 3,
        now: { 100 }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }
    await service.endInterruption(token: firstToken)

    guard let secondToken = await service.beginInterruption() else {
        Issue.record("Accepted exact-process lineage Pause should retain custody across lagging output.")
        return
    }
    #expect(driver.commands == [.pause, .play, .pause, .pause])

    await service.endInterruption(token: secondToken)
    #expect(driver.commands == [.pause, .play, .pause, .pause, .play])
}

@MainActor
@Test("Bounded resume lineage retains pending custody across partial observation loss")
func boundedResumeLineageRetainsPendingCustodyAcrossPartialObservationLoss() async {
    let unavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            unavailable,
            confirmedPlayingSnapshot,
            unavailable,
            unavailable,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0],
        resumeVerificationDelays: [0],
        resumeLineageGraceDuration: 3,
        now: { 100 }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }
    await service.endInterruption(token: firstToken)

    let secondToken = await service.beginInterruption()

    #expect(secondToken != nil)
    #expect(driver.commands.filter { $0 == .play }.count == 1)
}

@MainActor
@Test("Accepted bounded re-Pause remains pending until capture release proves silence")
func boundedResumeLineageDefersPlayUntilReleaseProof() async {
    let unavailable = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            unavailable,
            confirmedPlayingSnapshot,
            unavailable,
            unavailable,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0],
        resumeVerificationDelays: [0],
        resumeLineageGraceDuration: 3,
        now: { 100 }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }
    await service.endInterruption(token: firstToken)

    guard let secondToken = await service.beginInterruption() else {
        Issue.record("Accepted exact-lineage re-Pause should retain pending custody.")
        return
    }
    #expect(driver.commands == [.pause, .play, .pause])

    await service.endInterruption(token: secondToken)

    #expect(driver.commands == [.pause, .play, .pause, .play])
}

@MainActor
@Test("Partially unavailable bounded re-Pause remains pending until release proof")
func boundedResumeLineageDefersPlayAcrossPartialUnavailableEvidence() async {
    let partialUnavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            partialUnavailable,
            confirmedPlayingSnapshot,
            partialUnavailable,
            partialUnavailable,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0],
        resumeVerificationDelays: [0],
        resumeLineageGraceDuration: 3,
        now: { 100 }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }
    await service.endInterruption(token: firstToken)

    guard let secondToken = await service.beginInterruption() else {
        Issue.record("Partial observation loss must retain pending exact-lineage custody.")
        return
    }
    #expect(driver.commands == [.pause, .play, .pause])

    await service.endInterruption(token: secondToken)

    #expect(driver.commands == [.pause, .play, .pause, .play])
}

@MainActor
@Test("Pending bounded re-Pause rejects a replacement process at release")
func boundedResumeLineagePendingReleaseRejectsReplacement() async {
    let unavailable = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let replacementTarget = MediaPlaybackTarget(
        processID: primaryTarget.processID + 1,
        bundleIdentifier: primaryTarget.bundleIdentifier
    )
    let replacementOutput = MediaAudioOutputTarget(
        processID: primaryAudioOutput.processID + 1,
        applicationBundleIdentifier: primaryAudioOutput.applicationBundleIdentifier
    )
    let silentReplacement = makeSnapshot(
        target: replacementTarget,
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [replacementOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            unavailable,
            confirmedPlayingSnapshot,
            unavailable,
            unavailable,
            silentReplacement,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0],
        resumeVerificationDelays: [0],
        resumeLineageGraceDuration: 3,
        now: { 100 }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }
    await service.endInterruption(token: firstToken)
    guard let secondToken = await service.beginInterruption() else {
        Issue.record("Expected pending custody for the accepted exact-lineage re-Pause.")
        return
    }

    await service.endInterruption(token: secondToken)

    #expect(driver.commands == [.pause, .play, .pause])
}

@MainActor
@Test("Pending bounded re-Pause does not duplicate Play when original output is active")
func boundedResumeLineagePendingReleaseRejectsActiveOutput() async {
    let unavailable = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            unavailable,
            confirmedPlayingSnapshot,
            unavailable,
            unavailable,
            confirmedPlayingSnapshot,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0],
        resumeVerificationDelays: [0],
        resumeLineageGraceDuration: 3,
        now: { 100 }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }
    await service.endInterruption(token: firstToken)
    guard let secondToken = await service.beginInterruption() else {
        Issue.record("Expected pending custody for the accepted exact-lineage re-Pause.")
        return
    }

    await service.endInterruption(token: secondToken)

    #expect(driver.commands == [.pause, .play, .pause])
}

@MainActor
@Test("Bounded resume lineage ignores a silent elected-session replacement after re-Pause")
func boundedResumeLineageRejectsSilentReplacementAfterRePause() async {
    let unavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let replacementTarget = MediaPlaybackTarget(
        processID: primaryTarget.processID + 1,
        bundleIdentifier: primaryTarget.bundleIdentifier
    )
    let silentReplacement = makeSnapshot(
        target: replacementTarget,
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: []
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            unavailable,
            confirmedPlayingSnapshot,
            silentReplacement,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        resumeVerificationDelays: [0],
        resumeLineageGraceDuration: 3,
        now: { 100 }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }
    await service.endInterruption(token: firstToken)

    let secondToken = await service.beginInterruption()

    // A fresh snapshot with active output is a legitimate new interruption; the
    // elected session's process identity does not gate it.
    #expect(secondToken != nil)
    #expect(driver.commands == [.pause, .play, .pause])
}

@MainActor
@Test("Bounded resume lineage rejects a same-bundle replacement before re-Pause")
func boundedResumeLineageRejectsReplacementBeforeRePause() async {
    let unavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let replacementOutput = MediaAudioOutputTarget(
        processID: primaryAudioOutput.processID + 1,
        applicationBundleIdentifier: primaryAudioOutput.applicationBundleIdentifier
    )
    let activeReplacement = makeSnapshot(
        target: MediaPlaybackTarget(
            processID: primaryTarget.processID + 1,
            bundleIdentifier: primaryTarget.bundleIdentifier
        ),
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [replacementOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            unavailable,
            activeReplacement,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0],
        resumeVerificationDelays: [0],
        resumeLineageGraceDuration: 3,
        now: { 100 }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }
    await service.endInterruption(token: firstToken)

    let secondToken = await service.beginInterruption()

    #expect(secondToken == nil)
    #expect(
        driver.commands == [.pause, .play],
        "A stale process lineage must be rejected before it can Pause a replacement process."
    )
}

@MainActor
@Test("Bounded resume lineage does not re-Pause an exact process already reported stopped")
func boundedResumeLineageRejectsAlreadyStoppedRePausePreflight() async {
    let unavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let alreadyStoppedWithLaggingOutput = makeSnapshot(
        detection: .notPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            unavailable,
            alreadyStoppedWithLaggingOutput,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        resumeVerificationDelays: [0],
        resumeLineageGraceDuration: 3,
        now: { 100 }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }
    await service.endInterruption(token: firstToken)

    let secondToken = await service.beginInterruption()

    #expect(secondToken == nil)
    #expect(driver.commands == [.pause, .play])
}

@MainActor
@Test("Bounded resume lineage never retries re-Pause after a same-bundle process replacement")
func boundedResumeLineageDoesNotRetryRePauseAfterProcessReplacement() async {
    let unavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let replacementTarget = MediaPlaybackTarget(
        processID: primaryTarget.processID + 1,
        bundleIdentifier: primaryTarget.bundleIdentifier
    )
    let replacementOutput = MediaAudioOutputTarget(
        processID: primaryAudioOutput.processID + 1,
        applicationBundleIdentifier: primaryAudioOutput.applicationBundleIdentifier
    )
    let activeReplacement = makeSnapshot(
        target: replacementTarget,
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [replacementOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            unavailable,
            confirmedPlayingSnapshot,
            activeReplacement,
            activeReplacement,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0],
        resumeVerificationDelays: [0],
        resumeLineageGraceDuration: 3,
        now: { 100 }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }
    await service.endInterruption(token: firstToken)

    let secondToken = await service.beginInterruption()

    #expect(secondToken == nil)
    #expect(driver.commands == [.pause, .play, .pause])
}

@MainActor
@Test("Cancelled bounded-lineage re-Pause restores the accepted app once")
func cancelledBoundedLineageRePauseRestoresAcceptedAppOnce() async {
    let unavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let repauseGate = MediaSnapshotGate()
    let laggingPausedSnapshot = makeSnapshot(
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            unavailable,
            confirmedPlayingSnapshot,
            confirmedPlayingSnapshot,
            laggingPausedSnapshot,
            confirmedPausedSnapshot,
        ]
    )
    driver.sendGates[3] = repauseGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0, 0],
        resumeVerificationDelays: [0],
        resumeLineageGraceDuration: 3,
        now: { 100 }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }
    await service.endInterruption(token: firstToken)

    let secondBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    await waitUntil { repauseGate.waitCount == 1 }
    secondBegin.cancel()
    #expect(driver.commands.filter { $0 == .play }.count == 1)
    repauseGate.open()

    #expect(await secondBegin.value == nil)
    await waitUntil { driver.commands == [.pause, .play, .pause, .play] }
    #expect(driver.commands == [.pause, .play, .pause, .play])
    #expect(driver.snapshotCallCount >= 7)
}

@MainActor
@Test("A replacement owner prevents compensation from a cancelled bounded re-Pause")
func replacementOwnerPreventsCancelledBoundedRePauseCompensation() async {
    let unavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let replacementTarget = MediaPlaybackTarget(
        processID: primaryTarget.processID + 1,
        bundleIdentifier: primaryTarget.bundleIdentifier
    )
    let replacementOutput = MediaAudioOutputTarget(
        processID: primaryAudioOutput.processID + 1,
        applicationBundleIdentifier: primaryAudioOutput.applicationBundleIdentifier
    )
    let activeReplacement = makeSnapshot(
        target: replacementTarget,
        contentIdentifier: "item-2",
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [replacementOutput]
    )
    let repauseGate = MediaSnapshotGate()
    let verificationGate = MediaSnapshotGate()
    let cancellationProbe = CompletionProbe()
    let finalizationProbe = CompletionProbe()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            unavailable,
            confirmedPlayingSnapshot,
            activeReplacement,
        ]
    )
    driver.sendGates[3] = repauseGate
    driver.snapshotGates[5] = verificationGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        resumeVerificationDelays: [0],
        resumeLineageGraceDuration: 3,
        now: { 100 },
        afterPauseTransitionCancellation: {
            cancellationProbe.didComplete = true
        },
        afterPauseTransitionFinalization: {
            if driver.commands.filter({ $0 == .pause }).count >= 2 {
                finalizationProbe.didComplete = true
            }
        }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }
    await service.endInterruption(token: firstToken)

    let cancelledBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    await waitUntil { repauseGate.waitCount == 1 }
    cancelledBegin.cancel()
    await waitUntil { cancellationProbe.didComplete }

    let replacementBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    repauseGate.open()
    await waitUntil { verificationGate.waitCount == 1 }

    #expect(await cancelledBegin.value == nil)
    guard let replacementToken = await replacementBegin.value else {
        verificationGate.open()
        Issue.record("The replacement owner should receive accepted bounded custody.")
        return
    }
    #expect(driver.commands == [.pause, .play, .pause])

    verificationGate.open()
    await waitUntil { finalizationProbe.didComplete }

    #expect(driver.commands == [.pause, .play, .pause])
    #expect(driver.commands.filter { $0 == .play }.count == 1)
    await service.endInterruption(token: replacementToken)
    #expect(driver.commands == [.pause, .play, .pause])
}

@MainActor
@Test("A bounded-lineage re-Pause cannot Play under its new owner")
func boundedLineageRepauseCannotPlayUnderNewOwner() async {
    let unavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            unavailable,
            confirmedPlayingSnapshot,
            confirmedPlayingSnapshot,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        resumeVerificationDelays: [0],
        resumeLineageGraceDuration: 3,
        now: { 100 }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }
    await service.endInterruption(token: firstToken)

    let secondToken = await service.beginInterruption()
    #expect(secondToken == nil)
    #expect(driver.commands == [.pause, .play, .pause])
    if let secondToken {
        await service.endInterruption(token: secondToken)
    }
}

@MainActor
@Test("Bounded resume lineage narrows to the exact applications that accepted Play")
func boundedResumeLineageNarrowsToAcceptedPlayApplications() async {
    let secondaryAudioOutput = MediaAudioOutputTarget(
        processID: 84,
        applicationBundleIdentifier: "com.example.secondary"
    )
    let bothPlaying = makeSnapshot(
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [primaryAudioOutput, secondaryAudioOutput]
    )
    let unavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let primaryPlaying = makeSnapshot(
        detection: .playing,
        isPlaying: true,
        playbackState: 1,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            bothPlaying,
            confirmedPausedSnapshot,
            unavailable,
            primaryPlaying,
            confirmedPausedSnapshot,
        ]
    )
    driver.acceptedApplicationsBySend = [
        ["com.example.player", "com.example.secondary"],
        ["com.example.player"],
        ["com.example.player"],
        ["com.example.player"],
    ]
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        resumeVerificationDelays: [0],
        resumeLineageGraceDuration: 3,
        now: { 100 }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership for both applications.")
        return
    }
    await service.endInterruption(token: firstToken)

    guard let secondToken = await service.beginInterruption() else {
        Issue.record("Expected bounded ownership for the exact accepted Play subset.")
        return
    }
    await service.endInterruption(token: secondToken)

    #expect(driver.commands == [.pause, .play, .pause, .play])
    #expect(
        driver.destinations == [
            .observedApplications(["com.example.player", "com.example.secondary"]),
            .observedApplications(["com.example.player", "com.example.secondary"]),
            .observedApplications(["com.example.player"]),
            .observedApplications(["com.example.player"]),
        ]
    )
}

@MainActor
@Test("A begin arriving after resume completion consumes pending lineage before discovery")
func completedResumeJoinConsumesPendingLineageBeforeDiscovery() async {
    let unavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let finalizationGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            unavailable,
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        resumeVerificationDelays: [0],
        resumeLineageGraceDuration: 3,
        now: { 100 },
        beforeOwnerResumeFinalization: {
            if finalizationGate.waitCount == 0 {
                await finalizationGate.wait()
            }
        }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }

    let firstEnd = Task { @MainActor in
        await service.endInterruption(token: firstToken)
    }
    await waitUntil { finalizationGate.waitCount == 1 }
    #expect(driver.commands == [.pause, .play])

    let secondToken = await service.beginInterruption()
    finalizationGate.open()
    await firstEnd.value

    guard let secondToken else {
        Issue.record("The completed resume join should consume its exact pending lineage.")
        return
    }
    #expect(driver.commands == [.pause, .play, .pause])
    await service.endInterruption(token: secondToken)
    #expect(driver.commands == [.pause, .play, .pause, .play])
}

@MainActor
@Test("Rejected bounded-lineage Pause creates no ownership")
func rejectedBoundedLineagePauseCreatesNoOwnership() async {
    let unavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            unavailable,
            confirmedPlayingSnapshot,
        ]
    )
    driver.acceptedApplicationsBySend = [
        ["com.example.player"],
        ["com.example.player"],
        [],
    ]
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        resumeVerificationDelays: [0],
        resumeLineageGraceDuration: 3,
        now: { 100 }
    )
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }
    await service.endInterruption(token: firstToken)

    let secondToken = await service.beginInterruption()

    #expect(secondToken == nil)
    #expect(driver.commands == [.pause, .play, .pause])
    #expect(driver.commands.last == .pause)
}

@MainActor
@Test("Expired resume lineage cannot target or later resume paused media")
func expiredResumeLineageCannotTargetPausedMedia() async {
    let unavailable = makeSnapshot(
        detection: .unknown,
        isPlaying: nil,
        playbackState: nil,
        activeAudioOutputs: nil
    )
    var uptime: TimeInterval = 100
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            unavailable,
            confirmedPausedSnapshot,
        ]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0],
        resumeVerificationDelays: [0],
        resumeLineageGraceDuration: 3,
        now: { uptime }
    )
    guard let token = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }
    await service.endInterruption(token: token)
    #expect(driver.commands == [.pause, .play])

    uptime = 104
    let expiredBegin = await service.beginInterruption()

    #expect(expiredBegin == nil)
    #expect(driver.commands == [.pause, .play])
    #expect(driver.commands.last == .play)
}

@MainActor
@Test("Separate verified interruptions issue targeted Pause and Play pairs")
func separateVerifiedInterruptionsIssuePauseAndPlayPairs() async {
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
            confirmedPlayingSnapshot,
            confirmedPausedSnapshot,
        ]
    )
    let service = makeService(driver: driver)
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected the first interruption token.")
        return
    }
    await service.endInterruption(token: firstToken)
    guard let secondToken = await service.beginInterruption() else {
        Issue.record("Expected the second interruption token.")
        return
    }
    await service.endInterruption(token: secondToken)

    #expect(driver.commands == [.pause, .play, .pause, .play])
}

@MainActor
@Test("Media interruption ignores foreign and duplicate tokens")
func mediaInterruptionIgnoresForeignAndDuplicateTokens() async {
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, confirmedPausedSnapshot, confirmedPausedSnapshot]
    )
    let service = makeService(driver: driver)
    guard let token = await service.beginInterruption() else {
        Issue.record("Expected interruption token for verified playback.")
        return
    }

    await service.endInterruption(token: MediaInterruptionToken())
    #expect(driver.commands == [.pause])

    await service.endInterruption(token: token)
    #expect(driver.commands == [.pause, .play])

    await service.endInterruption(token: token)
    #expect(driver.commands == [.pause, .play])
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
@Test("Detector prefers strong-negative evidence over weak positives")
func detectorPrefersStrongNegativeOverWeakPositiveProbes() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.nowPlayingApplicationIsPlayingValue = true
    bridge.nowPlayingPlaybackRateValue = 0

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .notPlaying)
}

@MainActor
@Test("Detector returns not playing for trusted strong-negative state signal")
func detectorReturnsNotPlayingForTrustedStrongNegativeStateSignal() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.anyApplicationIsPlayingValue = true
    bridge.nowPlayingApplicationIsPlayingValue = true
    bridge.nowPlayingPlaybackStateValue = 2
    bridge.playbackStateIsAdvancingValue = false
    bridge.nowPlayingPlaybackRateValue = nil

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .notPlaying)
}

@MainActor
@Test("Detector treats error-default state=0 + rate=nil as weak-positive candidate")
func detectorTreatsErrorDefaultStateAsWeakPositiveCandidate() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.anyApplicationIsPlayingValue = true
    bridge.nowPlayingApplicationIsPlayingValue = false
    bridge.nowPlayingPlaybackStateValue = 0
    bridge.playbackStateIsAdvancingValue = false
    bridge.nowPlayingPlaybackRateValue = nil

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .likelyPlaying)
}

@MainActor
@Test("Detector treats uncorroborated nonzero state + weak-positive as likely playing")
func detectorTreatsUncorroboratedNonzeroStateAsWeakPositiveCandidate() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.anyApplicationIsPlayingValue = true
    bridge.nowPlayingApplicationIsPlayingValue = false
    bridge.nowPlayingPlaybackStateValue = 2
    bridge.playbackStateIsAdvancingValue = false
    bridge.nowPlayingPlaybackRateValue = nil

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .likelyPlaying)
}

@MainActor
@Test("Detector returns unknown for uncorroborated nonzero state without weak positives")
func detectorReturnsUnknownForUncorroboratedNonzeroStateWithoutWeakPositiveSignals() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.anyApplicationIsPlayingValue = false
    bridge.nowPlayingApplicationIsPlayingValue = false
    bridge.nowPlayingPlaybackStateValue = 2
    bridge.playbackStateIsAdvancingValue = false
    bridge.nowPlayingPlaybackRateValue = nil

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .unknown)
}

@MainActor
@Test("Detector returns unknown for transient weak-positive signal")
func detectorReturnsUnknownForTransientWeakPositiveSignal() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.anyApplicationIsPlayingSequence = [true, false]
    bridge.nowPlayingApplicationIsPlayingSequence = [false, false]
    bridge.nowPlayingPlaybackStateSequence = [0, 0]
    bridge.nowPlayingPlaybackRateSequence = [nil, nil]
    bridge.playbackStateIsAdvancingSequence = [false, false]

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .unknown)
}

@MainActor
@Test("Detector keeps not playing when rate=0 even if any=true")
func detectorKeepsNotPlayingWhenRateIsZeroAndAnyIsTrue() async {
    let bridge = FakeMediaRemoteBridge()
    bridge.anyApplicationIsPlayingValue = true
    bridge.nowPlayingPlaybackRateValue = 0

    let detector = MultiSignalMediaPlaybackStateDetector(bridge: bridge)
    let result = await detector.detect()

    #expect(result == .notPlaying)
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
@Test("Cancelled beginInterruption does not send a media command")
func cancelledBeginInterruptionDoesNotSendMediaCommand() async {
    let driver = FakeMediaInterruptionDriver(snapshots: [confirmedPlayingSnapshot])
    driver.snapshotDelayNanoseconds = 50_000_000
    let service = makeService(driver: driver)

    let task = Task { @MainActor in
        await service.beginInterruption()
    }
    task.cancel()

    let token = await task.value
    #expect(token == nil)
    #expect(driver.commands.isEmpty)
}

@MainActor
@Test("A pre-cancelled begin cannot join verified media custody")
func preCancelledBeginCannotJoinVerifiedCustody() async {
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, confirmedPausedSnapshot]
    )
    let service = makeService(driver: driver)
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected verified interruption ownership.")
        return
    }

    let cancelledBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    cancelledBegin.cancel()

    #expect(await cancelledBegin.value == nil)
    await service.endInterruption(token: firstToken)
    #expect(driver.commands == [.pause, .play])
}

@MainActor
@Test("A pre-cancelled begin cannot join pending media custody")
func preCancelledBeginCannotJoinPendingCustody() async {
    let ambiguousOriginal = makeSnapshot(
        detection: .unknown,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [primaryAudioOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [
            confirmedPlayingSnapshot,
            ambiguousOriginal,
            confirmedPausedSnapshot,
        ]
    )
    let service = makeService(driver: driver)
    guard let firstToken = await service.beginInterruption() else {
        Issue.record("Expected pending interruption ownership.")
        return
    }

    let cancelledBegin = Task { @MainActor in
        await service.beginInterruption()
    }
    cancelledBegin.cancel()

    #expect(await cancelledBegin.value == nil)
    await service.endInterruption(token: firstToken)
    #expect(driver.commands == [.pause, .play])
}

@MainActor
@Test("An elected session process outside the Core Audio domain never breaks custody")
func electedSessionProcessOutsideCoreAudioDomainKeepsCustody() async {
    let rendererOutput = MediaAudioOutputTarget(
        processID: 200,
        applicationBundleIdentifier: "com.google.Chrome"
    )
    // The elected now-playing session reports Chrome's main process while Core
    // Audio reports the renderer helper. They are different processes by
    // construction, so the mismatch is not evidence about custody.
    let chromeIsActive = makeSnapshot(
        target: MediaPlaybackTarget(
            processID: 100,
            bundleIdentifier: "com.google.Chrome"
        ),
        contentIdentifier: "video-1",
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [rendererOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: Array(repeating: chromeIsActive, count: 6)
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("A split-process application must still take custody of its accepted Pause.")
        return
    }
    await service.endInterruption(token: token)

    #expect(driver.commands.filter { $0 == .play }.count == 1)
    #expect(
        driver.verifiedDestinations.last?.expectedProcessTargets == [rendererOutput],
        "Resume must bind the Core Audio producer, not the elected session process."
    )
}

@MainActor
@Test("Content drift under a preserved Core Audio producer never breaks custody")
func contentDriftUnderPreservedProducerKeepsCustody() async {
    let producerOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let electedSession = MediaPlaybackTarget(
        processID: 63_508,
        bundleIdentifier: "com.apple.podcasts"
    )
    let before = makeSnapshot(
        target: electedSession,
        contentIdentifier: "episode-1",
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [producerOutput]
    )
    // The elected session advances to the next item while the exact same Core
    // Audio producer stays open. Elected content is advisory only.
    let contentDrifted = makeSnapshot(
        target: electedSession,
        contentIdentifier: "episode-2",
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [producerOutput]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [before] + Array(repeating: contentDrifted, count: 5)
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("Elected content drift must not discard custody of a preserved producer.")
        return
    }
    await service.endInterruption(token: token)

    #expect(driver.commands.filter { $0 == .play }.count == 1)
}

@MainActor
@Test("Teardown observed after the ladder but before release verifies custody")
func teardownAfterLadderBeforeReleaseVerifiesCustody() async {
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    let openStream = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    // Core Audio teardown outlasts the whole verification ladder but lands
    // before capture release, so pending custody upgrades to verified.
    let tornDown = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: []
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: [openStream, openStream, openStream, tornDown]
    )
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )

    guard let token = await service.beginInterruption() else {
        Issue.record("An accepted Pause with lagging teardown must hold pending custody.")
        return
    }
    await service.endInterruption(token: token)

    #expect(driver.commands.filter { $0 == .play }.count == 1)
    #expect(
        driver.verifiedDestinations.last?.expectedProcessTargets == [podcastsOutput]
    )
}

@MainActor
@Test("A silent stream holder that rejects the Pause creates no custody and no compensation")
func silentStreamHolderRejectingPauseCreatesNoCustody() async {
    let silentStreamHolder = MediaAudioOutputTarget(
        processID: 4_242,
        applicationBundleIdentifier: "com.example.silent-stream-holder"
    )
    // An application can hold an open, silent output stream without any media
    // session. Core Audio reports it as active output, so it reaches the
    // destination, but it has no session to accept a semantic Pause.
    let holderIsActiveOutput = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [silentStreamHolder]
    )
    let driver = FakeMediaInterruptionDriver(
        snapshots: Array(repeating: holderIsActiveOutput, count: 3)
    )
    driver.acceptedApplicationsBySend = [[]]
    let service = MacMediaInterruptionService(driver: driver, verificationDelays: [0])

    let token = await service.beginInterruption()

    #expect(token == nil, "A rejected Pause must not create custody.")
    #expect(driver.commands == [.pause], "Nothing was accepted, so nothing needs compensating.")
    #expect(!driver.commands.contains(.play))
}

@MainActor
@Test("Releasing an owner holding uncontradicted custody resumes exactly once")
func releasedOwnerHoldingUncontradictedCustodyResumesExactlyOnce() async {
    let podcastsOutput = MediaAudioOutputTarget(
        processID: 63_508,
        applicationBundleIdentifier: "com.apple.podcasts"
    )
    // Output teardown lags the accepted Pause, so custody stays pending and
    // uncontradicted for the whole window. The owner releases mid-verification.
    let laggingOpenStream = makeSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        isPlaying: false,
        playbackState: 2,
        activeAudioOutputs: [podcastsOutput]
    )
    let verificationGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: Array(repeating: laggingOpenStream, count: 5)
    )
    driver.snapshotGates[2] = verificationGate
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: [0, 0]
    )

    let completion = CompletionProbe()
    let begin = Task { @MainActor in
        let token = await service.beginInterruption()
        completion.didComplete = true
        return token
    }
    await waitUntil { verificationGate.waitCount == 1 }
    #expect(driver.commands == [.pause])
    await waitUntil { completion.didComplete }
    guard completion.didComplete, let token = await begin.value else {
        verificationGate.open()
        _ = await begin.value
        Issue.record("Pending custody should be returned before verification completes.")
        return
    }

    let release = Task { @MainActor in
        await service.endInterruption(token: token)
    }
    await Task.yield()
    #expect(!driver.commands.contains(.play))
    verificationGate.open()

    await release.value
    await waitUntil { driver.commands.contains(.play) }

    // The accepted Pause resolves through the release path. It must not also be
    // compensated, which would emit a second Play to the same application.
    #expect(
        driver.commands.filter { $0 == .play }.count == 1,
        "An accepted Pause must resolve with exactly one Play, never a duplicate."
    )
    #expect(
        driver.verifiedDestinations.last?.expectedProcessTargets == [podcastsOutput]
    )
}

@MainActor
private func makeCommandBridge(
    timeout: DispatchTimeInterval = .milliseconds(250),
    dispatch: @escaping @MainActor (
        SemanticMediaCommand,
        String,
        @escaping @Sendable (UInt32) -> Void
    ) -> Bool
) -> MediaRemoteBridge {
    MediaRemoteBridge(
        frameworkPath: "/does/not/exist",
        probeRunner: MediaRemoteAsyncProbeRunner(
            timeout: timeout,
            timeoutQueue: DispatchQueue(label: "StenoTests.MediaRemote.CommandTimeout")
        ),
        sendCommandOverride: dispatch
    )
}

@MainActor
@Test("Targeted media command acceptance requires a zero-error callback")
func targetedMediaCommandAcceptanceRequiresZeroErrorCallback() async {
    let bridge = makeCommandBridge { command, applicationBundleIdentifier, acknowledge in
        #expect(command == .pause)
        #expect(applicationBundleIdentifier == "com.example.player")
        acknowledge(0)
        return true
    }

    #expect(
        await bridge.send(
            .pause,
            toApplicationBundleIdentifier: "com.example.player"
        )
    )
}

@MainActor
@Test("A nonzero command callback error is not acceptance")
func nonzeroCommandCallbackErrorIsNotAcceptance() async {
    let bridge = makeCommandBridge { _, _, acknowledge in
        // A running application without a registered now-playing session reports
        // error 1 even though the dispatch itself claims success.
        acknowledge(1)
        return true
    }

    #expect(
        !(await bridge.send(
            .pause,
            toApplicationBundleIdentifier: "com.example.player"
        ))
    )
}

@MainActor
@Test("A command callback that never arrives is not acceptance")
func absentCommandCallbackIsNotAcceptance() async {
    let bridge = makeCommandBridge(timeout: .milliseconds(20)) { _, _, _ in
        // Dispatch claims success synchronously and never acknowledges.
        true
    }

    #expect(
        !(await bridge.send(
            .pause,
            toApplicationBundleIdentifier: "com.example.player"
        ))
    )
}

@MainActor
@Test("A rejected synchronous dispatch is not acceptance")
func rejectedSynchronousDispatchIsNotAcceptance() async {
    let bridge = makeCommandBridge(timeout: .milliseconds(20)) { _, _, _ in false }

    #expect(
        !(await bridge.send(
            .pause,
            toApplicationBundleIdentifier: "com.example.player"
        ))
    )
}

@MainActor
@Test("An empty application identifier is never dispatched")
func emptyApplicationIdentifierIsNeverDispatched() async {
    var dispatchCount = 0
    let bridge = makeCommandBridge(timeout: .milliseconds(20)) { _, _, acknowledge in
        dispatchCount += 1
        acknowledge(0)
        return true
    }

    #expect(!(await bridge.send(.pause, toApplicationBundleIdentifier: "")))
    #expect(dispatchCount == 0)
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
