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

@MainActor
private final class FakeMediaInterruptionDriver: MediaInterruptionDriving {
    private var snapshots: [MediaInterruptionSnapshot]
    private let fallbackSnapshot: MediaInterruptionSnapshot
    var sendResults: [Bool]
    var acceptedApplicationsBySend: [[String]] = []
    private(set) var commands: [SemanticMediaCommand] = []
    private(set) var destinations: [MediaPauseDestination] = []
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

    func sendPlay(
        to destination: VerifiedMediaResumeDestination
    ) async -> MediaCommandDispatchResult {
        sendCallCount += 1
        commands.append(.play)
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

    func wait() async {
        waitCount += 1
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
}

@MainActor
private final class CompletionProbe {
    var didStart = false
    var didComplete = false
}

@MainActor
private func waitUntil(
    _ predicate: @escaping @MainActor () -> Bool,
    attempts: Int = 1_000
) async {
    for _ in 0..<attempts {
        if predicate() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for test condition.")
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
@Test("Every accepted Pause must verify before interruption ownership is created")
func allAcceptedPauseApplicationsMustVerify() async {
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

    #expect(token == nil)
    #expect(driver.commands == [.pause, .pause, .play])
    #expect(
        driver.destinations == [
            .observedApplications(["com.example.Alpha", "com.example.Beta"]),
            .observedApplications(["com.example.Beta"]),
            .observedApplications(["com.example.Alpha", "com.example.Beta"]),
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
            for: 81955,
            fallback: "com.google.Chrome.helper"
        ) == "com.google.Chrome"
    )
}

@Test("Active audio PID lookup failure is counted as unresolved ownership")
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
                processID: nil,
                fallbackBundleIdentifier: nil
            ),
            ActiveAudioProcessRecord(
                processID: 42,
                fallbackBundleIdentifier: "com.example.player"
            ),
        ],
        excludingProcessID: 99
    )

    #expect(observation.unresolvedProcessCount == 1)
    #expect(observation.targets == [primaryAudioOutput])
}

@MainActor
@Test("An accepted but unverified Pause is compensated without creating ownership")
func unverifiedPauseIsCompensatedWithoutOwnership() async {
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, confirmedPlayingSnapshot]
    )
    let service = makeService(driver: driver)

    let token = await service.beginInterruption()

    #expect(token == nil)
    #expect(driver.commands == [.pause, .play])
    #expect(
        driver.destinations == [
            .observedApplications(["com.example.player"]),
            .observedApplications(["com.example.player"]),
        ]
    )
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
@Test("Cancellation after Pause restores verified media exactly once")
func cancelledVerifiedPauseRestoresMediaExactlyOnce() async {
    let verificationGate = MediaSnapshotGate()
    let driver = FakeMediaInterruptionDriver(
        snapshots: [confirmedPlayingSnapshot, confirmedPausedSnapshot]
    )
    driver.snapshotGates[2] = verificationGate
    let service = makeService(driver: driver)

    let begin = Task { @MainActor in await service.beginInterruption() }
    await waitUntil { verificationGate.waitCount == 1 }
    #expect(driver.commands == [.pause])

    begin.cancel()
    await Task.yield()
    verificationGate.open()

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
            unavailable,
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
            unavailable,
            primaryPlaying,
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
            unavailable,
            confirmedPlayingSnapshot,
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
@Test("Targeted MediaRemote command uses synchronous acceptance without a callback")
func targetedMediaRemoteCommandUsesSynchronousAcceptance() async {
    let acceptedBridge = MediaRemoteBridge(
        frameworkPath: "/does/not/exist",
        sendCommandOverride: { command, applicationBundleIdentifier in
            #expect(command == .pause)
            #expect(applicationBundleIdentifier == "com.example.player")
            return true
        }
    )
    let rejectedBridge = MediaRemoteBridge(
        frameworkPath: "/does/not/exist",
        sendCommandOverride: { _, _ in false }
    )

    #expect(
        await acceptedBridge.send(
            .pause,
            toApplicationBundleIdentifier: "com.example.player"
        )
    )
    #expect(
        !(await rejectedBridge.send(
            .pause,
            toApplicationBundleIdentifier: "com.example.player"
        ))
    )
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
