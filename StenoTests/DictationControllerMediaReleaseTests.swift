import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

// Drives the production MacMediaInterruptionService through the real
// DictationController, with a scripted Core Audio / MediaRemote driver.

@MainActor
@Test("On an unsupported macOS, dictation never probes media or sends a media command")
func unsupportedSystemDictationSendsNoMediaCommand() async {
    let events = MediaReleaseEventLog()
    let driver = ScriptedMediaDriver(events: events, snapshots: [playingPodcasts()])
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: MacMediaInterruptionService.defaultVerificationDelays,
        resumeVerificationDelays: productionResumeDelays,
        sleep: { try? await Task.sleep(nanoseconds: $0) },
        systemSupportsMediaPausing: false
    )
    let controller = makeTestDictationController(
        hotkey: MediaReleaseHotkeyService(),
        mediaInterruption: service,
        coordinator: MediaReleaseCoordinator(events: events)
    )
    #expect(controller.preferences.media.pauseDuringPressToTalk)
    #expect(controller.preferences.media.pauseDuringHandsFree)

    for handsFree in [false, true] {
        let starts = events.count("capture.ready")
        if handsFree { controller.toggleHandsFree() } else { controller.pressToTalkStart() }
        #expect(await events.waitForCount("capture.ready", starts + 1))
        let transcriptions = events.count("transcription.start")
        if handsFree { controller.toggleHandsFree() } else { controller.pressToTalkStop() }
        #expect(await events.waitForCount("transcription.start", transcriptions + 1))
        #expect(await waitForIdle(controller))
    }

    #expect(driver.snapshotCallCount == 0)
    #expect(driver.commands.isEmpty)
    await controller.teardownAndWait()
}

// MARK: - Transcription does not wait for the media resume

/// Transcription must begin promptly after capture stops, whatever the paused
/// application does next. The production resume ladder alone lasts over two
/// seconds when playback is never observed again.
private let transcriptionStartBound: Duration = .milliseconds(350)

struct MediaReleaseScenario: CustomTestStringConvertible, Sendable {
    let label: String
    let holdMilliseconds: UInt64
    let snapshots: [MediaInterruptionSnapshot]

    var testDescription: String { label }

    static let all: [MediaReleaseScenario] = [
        // Podcasts-like player whose output stream stays open for seconds after
        // an accepted Pause, so the release drains the pause ladder.
        MediaReleaseScenario(
            label: "stream still open, quick press",
            holdMilliseconds: 200,
            snapshots: Array(repeating: playingPodcasts(), count: 40)
        ),
        MediaReleaseScenario(
            label: "stream still open, one-second hold",
            holdMilliseconds: 1_000,
            snapshots: Array(repeating: playingPodcasts(), count: 40)
        ),
        // Output closed before release; the app restarts it only after the
        // resume ladder's third pass.
        MediaReleaseScenario(
            label: "stream closed, output returns late",
            holdMilliseconds: 1_000,
            snapshots: [playingPodcasts()]
                + Array(repeating: playingPodcasts(), count: 3)
                + Array(repeating: silentOutput(), count: 5)
                + [playingPodcasts()]
        ),
        // The paused app quits during dictation, so Play is never observed and
        // the whole resume ladder runs.
        MediaReleaseScenario(
            label: "paused app quits",
            holdMilliseconds: 1_000,
            snapshots: [playingPodcasts(), playingPodcasts(), silentOutput()]
        ),
    ]
}

@MainActor
@Test("Transcription starts promptly after stop while the media resume runs", arguments: MediaReleaseScenario.all)
func transcriptionStartsPromptlyWhileMediaResumes(scenario: MediaReleaseScenario) async {
    let harness = MediaReleaseHarness(snapshots: scenario.snapshots, snapshotDelayMilliseconds: 100)
    let controller = harness.controller
    let events = harness.events

    controller.pressToTalkStart()
    guard await events.waitForCount("media.begin.token", 1) else {
        Issue.record("No pause ownership: \(events.names())")
        await controller.teardownAndWait()
        return
    }
    try? await Task.sleep(nanoseconds: scenario.holdMilliseconds * 1_000_000)
    controller.pressToTalkStop()

    #expect(await events.waitForCount("transcription.start", 1))
    #expect(await events.waitForCount("media.release.end", 1))
    let names = events.names()
    guard let stoppedAt = events.instant(of: "capture.stop"),
          let transcribedAt = events.instant(of: "transcription.start"),
          let releaseBegin = events.index(of: "media.release.begin"),
          let releaseEnd = events.index(of: "media.release.end"),
          let transcription = events.index(of: "transcription.start"),
          let captureStop = events.index(of: "capture.stop")
    else {
        Issue.record("Missing lifecycle events: \(names)")
        await controller.teardownAndWait()
        return
    }
    let wait = transcribedAt - stoppedAt
    #expect(wait < transcriptionStartBound, "Transcription waited \(wait) after stop: \(names)")
    // The resume starts before transcription and after capture closed; it
    // finishes on its own schedule.
    #expect(captureStop < releaseBegin)
    #expect(releaseBegin < transcription)
    #expect(transcription < releaseEnd)
    #expect(harness.driver.commands.first == .pause)
    #expect(harness.driver.commands.contains(.play))
    #expect(harness.media.endedTokens == harness.media.begunTokens)
    await controller.teardownAndWait()
}

@MainActor
@Test("A release before media setup finishes does not hold up transcription")
func quickTapReleaseDoesNotHoldUpTranscription() async {
    let harness = MediaReleaseHarness(
        snapshots: Array(repeating: playingPodcasts(), count: 40),
        snapshotDelayMilliseconds: 150
    )
    let controller = harness.controller
    let events = harness.events

    controller.pressToTalkStart()
    guard await events.waitForCount("capture.ready", 1) else {
        Issue.record("Capture never started: \(events.names())")
        await controller.teardownAndWait()
        return
    }
    // Key-up lands while beginInterruption is still probing media state.
    controller.pressToTalkStop()

    #expect(await events.waitForCount("transcription.start", 1))
    #expect(await events.waitForCount("media.release.end", 1))
    guard let stoppedAt = events.instant(of: "capture.stop"),
          let transcribedAt = events.instant(of: "transcription.start"),
          let releaseBegin = events.index(of: "media.release.begin"),
          let transcription = events.index(of: "transcription.start")
    else {
        Issue.record("Missing lifecycle events: \(events.names())")
        await controller.teardownAndWait()
        return
    }
    // Media setup itself (one probe plus Pause) may finish first; the resume
    // ladder must not.
    let wait = transcribedAt - stoppedAt
    #expect(wait < .milliseconds(600), "Transcription waited \(wait) after stop: \(events.names())")
    #expect(releaseBegin < transcription)
    #expect(harness.driver.commands.first == .pause)
    #expect(harness.driver.commands.contains(.play))
    #expect(harness.media.endedTokens == harness.media.begunTokens)
    await controller.teardownAndWait()
}

@MainActor
@Test("Cancel followed by an immediate press starts capture without waiting for the resume")
func cancelThenImmediatePressIsNotBlockedByResume() async {
    // The stream stays open, so the cancelled session's release drains the
    // full pause ladder before it can adjudicate.
    let harness = MediaReleaseHarness(
        snapshots: Array(repeating: playingPodcasts(), count: 80),
        snapshotDelayMilliseconds: 100
    )
    let controller = harness.controller
    let events = harness.events

    controller.pressToTalkStart()
    guard await events.waitForCount("media.begin.token", 1) else {
        Issue.record("No pause ownership: \(events.names())")
        await controller.teardownAndWait()
        return
    }
    let cancelledAt = ContinuousClock.now
    controller.cancelActiveRecording()
    controller.pressToTalkStart()

    #expect(await events.waitForCount("capture.start", 2))
    guard let restartedAt = events.instant(of: "capture.start", occurrence: 2) else {
        Issue.record("Second capture never started: \(events.names())")
        await controller.teardownAndWait()
        return
    }
    let wait = restartedAt - cancelledAt
    #expect(wait < transcriptionStartBound, "New press waited \(wait) after Cancel: \(events.names())")

    // The new session owns its own token and never inherits the cancelled
    // session's release.
    #expect(await events.waitForCount("media.begin.token", 2))
    #expect(harness.media.begunTokens.count == 2)
    #expect(Set(harness.media.begunTokens).count == 2)
    #expect(await events.waitForCount("media.release.end", 1))
    #expect(harness.media.endedTokens == [harness.media.begunTokens[0]])
    // Media stays paused for the new owner: the cancelled release never plays.
    #expect(!harness.driver.commands.contains(.play))
    #expect(controller.isRecording)

    controller.pressToTalkStop()
    #expect(await events.waitForCount("media.release.end", 2))
    #expect(harness.media.endedTokens == harness.media.begunTokens)
    #expect(harness.driver.commands.filter { $0 == .play }.count == 1)
    #expect(harness.driver.commands.last == .play)
    await controller.teardownAndWait()
}

@MainActor
@Test("An in-flight resume never sends Play for a newer capture")
func inFlightResumeNeverPlaysForNewerCapture() async {
    // Output never returns after Play, so the first session's resume ladder
    // keeps verifying (and retrying Play) when the next press arrives.
    let harness = MediaReleaseHarness(
        snapshots: [playingPodcasts(), playingPodcasts(), silentOutput()],
        snapshotDelayMilliseconds: 20
    )
    let controller = harness.controller
    let events = harness.events

    controller.pressToTalkStart()
    guard await events.waitForCount("media.begin.token", 1) else {
        Issue.record("No pause ownership: \(events.names())")
        await controller.teardownAndWait()
        return
    }
    controller.pressToTalkStop()
    #expect(await events.waitForCount("media.command.play", 1))
    #expect(await waitForIdle(controller))
    // The first session finished while its resume is still verifying.
    #expect(events.count("media.release.end") == 0)

    controller.pressToTalkStart()
    #expect(await events.waitForCount("capture.ready", 2))
    let secondBegin = await waitForAny(["media.begin.token", "media.begin.none"], total: 2, in: events)
    #expect(secondBegin)
    let playsWhenNewCaptureOwnsMedia = harness.driver.commands.filter { $0 == .play }.count
    // Joining cancels the stale resume ladder, so its release finishes now.
    #expect(await events.waitForCount("media.release.end", 1, attempts: 200))
    try? await Task.sleep(nanoseconds: 400_000_000)
    #expect(harness.driver.commands.filter { $0 == .play }.count == playsWhenNewCaptureOwnsMedia)
    #expect(controller.isRecording)

    controller.pressToTalkStop()
    #expect(await waitForIdle(controller))
    try? await Task.sleep(nanoseconds: 400_000_000)
    // The app never produced output again, so nothing verifies a new Pause
    // and no Play is owed to the newer capture either.
    #expect(harness.driver.commands.filter { $0 == .play }.count == playsWhenNewCaptureOwnsMedia)
    await controller.teardownAndWait()
    #expect(harness.media.endedTokens == harness.media.begunTokens)
}

func waitForAny(
    _ names: Set<String>,
    total: Int,
    in events: MediaReleaseEventLog,
    attempts: Int = 800
) async -> Bool {
    for _ in 0..<attempts {
        if names.map({ events.count($0) }).reduce(0, +) >= total { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

@MainActor
@Test("The paused app quitting mid-dictation neither delays transcription nor outlives teardown")
func pausedAppQuitWithConcurrentResume() async {
    let harness = MediaReleaseHarness(
        snapshots: Array(repeating: playingPodcasts(), count: 80),
        snapshotDelayMilliseconds: 50
    )
    let controller = harness.controller
    let events = harness.events

    controller.pressToTalkStart()
    guard await events.waitForCount("media.begin.token", 1) else {
        Issue.record("No pause ownership: \(events.names())")
        await controller.teardownAndWait()
        return
    }
    // The paused app quits: its output disappears and never returns.
    harness.driver.script([silentOutput()])
    try? await Task.sleep(nanoseconds: 500_000_000)
    controller.pressToTalkStop()

    #expect(await events.waitForCount("transcription.start", 1))
    guard let stoppedAt = events.instant(of: "capture.stop"),
          let transcribedAt = events.instant(of: "transcription.start")
    else {
        Issue.record("Missing lifecycle events: \(events.names())")
        await controller.teardownAndWait()
        return
    }
    #expect(transcribedAt - stoppedAt < transcriptionStartBound)
    #expect(events.count("media.release.end") == 0)

    // Quitting Steno waits for the in-flight resume to finish.
    await controller.teardownAndWait()
    #expect(events.count("media.release.end") == 1)
    #expect(harness.media.endedTokens == harness.media.begunTokens)
    guard let releaseEnd = events.index(of: "media.release.end"),
          let shutdown = events.index(of: "runtime.shutdown")
    else {
        Issue.record("Missing teardown events: \(events.names())")
        return
    }
    #expect(releaseEnd < shutdown)
}

// MARK: - Fixtures

@MainActor
final class MediaReleaseHarness {
    let events = MediaReleaseEventLog()
    let driver: ScriptedMediaDriver
    let media: ObservedMediaService
    let controller: DictationController

    init(snapshots: [MediaInterruptionSnapshot], snapshotDelayMilliseconds: UInt64) {
        driver = ScriptedMediaDriver(
            events: events,
            snapshots: snapshots,
            snapshotDelayNanoseconds: snapshotDelayMilliseconds * 1_000_000
        )
        let service = MacMediaInterruptionService(
            driver: driver,
            verificationDelays: MacMediaInterruptionService.defaultVerificationDelays,
            resumeVerificationDelays: productionResumeDelays,
            sleep: { try? await Task.sleep(nanoseconds: $0) },
            systemSupportsMediaPausing: true
        )
        media = ObservedMediaService(inner: service, events: events)
        controller = makeTestDictationController(
            hotkey: MediaReleaseHotkeyService(),
            mediaInterruption: media,
            coordinator: MediaReleaseCoordinator(events: events)
        )
    }
}

/// Records when the controller begins and finishes each media call, then
/// forwards to the production service unchanged.
@MainActor
final class ObservedMediaService: MediaInterruptionService {
    private let inner: MediaInterruptionService
    private let events: MediaReleaseEventLog
    private(set) var begunTokens: [UUID] = []
    private(set) var endedTokens: [UUID] = []

    init(inner: MediaInterruptionService, events: MediaReleaseEventLog) {
        self.inner = inner
        self.events = events
    }

    func beginInterruption() async -> MediaInterruptionToken? {
        let token = await inner.beginInterruption()
        if let token {
            begunTokens.append(token.id)
            events.append("media.begin.token")
        } else {
            events.append("media.begin.none")
        }
        return token
    }

    func endInterruption(token: MediaInterruptionToken) async {
        endedTokens.append(token.id)
        events.append("media.release.begin")
        await inner.endInterruption(token: token)
        events.append("media.release.end")
    }
}


let productionResumeDelays: [UInt64] = [
    80_000_000, 120_000_000, 200_000_000, 400_000_000, 800_000_000, 800_000_000,
]

let podcastsOutput = MediaAudioOutputTarget(
    processID: 63_508,
    applicationBundleIdentifier: "com.apple.podcasts",
    processStartTimeMicroseconds: 1
)

/// The production snapshot shape: no elected now-playing target, a stuck
/// weak-positive playback signal, and Core Audio output from the app.
func productionSnapshot(_ outputs: [MediaAudioOutputTarget]) -> MediaInterruptionSnapshot {
    MediaInterruptionSnapshot(
        target: nil,
        contentIdentifier: nil,
        detection: .likelyPlaying,
        nowPlayingIsPlaying: nil,
        playbackState: nil,
        audioOutputObservation: MediaAudioOutputObservation(
            targets: outputs,
            unresolvedProcessCount: 0
        )
    )
}

func playingPodcasts() -> MediaInterruptionSnapshot {
    productionSnapshot([podcastsOutput])
}

func silentOutput() -> MediaInterruptionSnapshot {
    productionSnapshot([])
}

@MainActor
func waitForIdle(_ controller: DictationController, attempts: Int = 600) async -> Bool {
    for _ in 0..<attempts {
        if controller.recordingLifecycleState == .idle { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

/// Synchronous so a wrapper can record the instant a call begins without
/// introducing a suspension point ahead of the call it observes.
final class MediaReleaseEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(name: String, at: ContinuousClock.Instant)] = []

    func append(_ name: String) {
        lock.withLock { events.append((name, ContinuousClock.now)) }
    }

    func names() -> [String] {
        lock.withLock { events.map(\.name) }
    }

    func count(_ name: String) -> Int {
        lock.withLock { events.filter { $0.name == name }.count }
    }

    func instant(of name: String, occurrence: Int = 1) -> ContinuousClock.Instant? {
        lock.withLock { events.filter { $0.name == name }.dropFirst(occurrence - 1).first?.at }
    }

    func index(of name: String, occurrence: Int = 1) -> Int? {
        lock.withLock {
            events.indices.filter { events[$0].name == name }.dropFirst(occurrence - 1).first
        }
    }

    func waitForCount(_ name: String, _ count: Int, attempts: Int = 1_200) async -> Bool {
        for _ in 0..<attempts {
            if self.count(name) >= count { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}

/// Replays scripted snapshots with an injected per-snapshot latency and
/// accepts every command, the way MediaRemote acknowledges a running player.
@MainActor
final class ScriptedMediaDriver: MediaInterruptionDriving {
    private let events: MediaReleaseEventLog
    private var snapshots: [MediaInterruptionSnapshot]
    private var fallback: MediaInterruptionSnapshot
    var snapshotDelayNanoseconds: UInt64
    private(set) var commands: [SemanticMediaCommand] = []
    private(set) var snapshotCallCount = 0

    init(
        events: MediaReleaseEventLog,
        snapshots: [MediaInterruptionSnapshot],
        snapshotDelayNanoseconds: UInt64 = 0
    ) {
        self.events = events
        self.snapshots = snapshots
        self.fallback = snapshots.last ?? silentOutput()
        self.snapshotDelayNanoseconds = snapshotDelayNanoseconds
    }

    /// Replaces the remaining script, e.g. when the paused app quits.
    func script(_ snapshots: [MediaInterruptionSnapshot]) {
        self.snapshots = snapshots
        fallback = snapshots.last ?? fallback
    }

    func snapshot() async -> MediaInterruptionSnapshot {
        snapshotCallCount += 1
        if snapshotDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: snapshotDelayNanoseconds)
        }
        guard !snapshots.isEmpty else { return fallback }
        return snapshots.removeFirst()
    }

    func sendPause(to destination: MediaPauseDestination) async -> MediaCommandDispatchResult {
        await record(.pause)
        return MediaCommandDispatchResult(
            acceptedApplicationBundleIdentifiers: destination.applicationBundleIdentifiers
        )
    }

    func sendPause(to destination: VerifiedMediaResumeDestination) async -> MediaCommandDispatchResult {
        await record(.pause)
        return MediaCommandDispatchResult(
            acceptedApplicationBundleIdentifiers: destination.applicationBundleIdentifiers
        )
    }

    func sendPlay(to destination: VerifiedMediaResumeDestination) async -> MediaCommandDispatchResult {
        await record(.play)
        return MediaCommandDispatchResult(
            acceptedApplicationBundleIdentifiers: destination.applicationBundleIdentifiers
        )
    }

    private func record(_ command: SemanticMediaCommand) async {
        commands.append(command)
        events.append(command == .pause ? "media.command.pause" : "media.command.play")
    }
}

actor MediaReleaseCoordinator: DictationSessionCoordinating {
    private let events: MediaReleaseEventLog

    init(events: MediaReleaseEventLog) {
        self.events = events
    }

    func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        events.append("capture.start")
        return SessionID()
    }

    func endPressToTalkCapture(sessionID: SessionID) async throws {
        events.append("capture.stop")
    }

    func completePressToTalk(
        sessionID: SessionID,
        languageHints: [String]
    ) async throws -> InsertResult {
        events.append("transcription.start")
        return InsertResult(status: .noSpeech, method: .none, insertedText: "")
    }

    func cancel(sessionID: SessionID) async {
        events.append("capture.cancel")
    }

    func setHandsFreeEnabled(_ enabled: Bool) async {
        events.append("capture.ready")
    }

    func unloadTranscriptionRuntime() async {
        events.append("runtime.unload")
    }

    func shutdown() async {
        events.append("runtime.shutdown")
    }
}

@MainActor
final class MediaReleaseHotkeyService: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16?

    func start() {
        onRegistrationStatusChanged?(.registered)
    }

    func stop() {}
}
