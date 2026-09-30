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
        let starts = await events.count("capture.ready")
        if handsFree { controller.toggleHandsFree() } else { controller.pressToTalkStart() }
        #expect(await events.waitForCount("capture.ready", starts + 1))
        let transcriptions = await events.count("transcription.start")
        if handsFree { controller.toggleHandsFree() } else { controller.pressToTalkStop() }
        #expect(await events.waitForCount("transcription.start", transcriptions + 1))
        #expect(await waitForIdle(controller))
    }

    #expect(driver.snapshotCallCount == 0)
    #expect(driver.commands.isEmpty)
    await controller.teardownAndWait()
}

// MARK: - Fixtures

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

actor MediaReleaseEventLog {
    private(set) var events: [(name: String, at: ContinuousClock.Instant)] = []

    func append(_ name: String) {
        events.append((name, ContinuousClock.now))
    }

    func names() -> [String] {
        events.map(\.name)
    }

    func count(_ name: String) -> Int {
        events.filter { $0.name == name }.count
    }

    func instant(of name: String, occurrence: Int = 1) -> ContinuousClock.Instant? {
        events.filter { $0.name == name }.dropFirst(occurrence - 1).first?.at
    }

    func waitForCount(_ name: String, _ count: Int, attempts: Int = 800) async -> Bool {
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
        await events.append(command == .pause ? "media.command.pause" : "media.command.play")
    }
}

actor MediaReleaseCoordinator: DictationSessionCoordinating {
    private let events: MediaReleaseEventLog

    init(events: MediaReleaseEventLog) {
        self.events = events
    }

    func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        await events.append("capture.start")
        return SessionID()
    }

    func endPressToTalkCapture(sessionID: SessionID) async throws {
        await events.append("capture.stop")
    }

    func completePressToTalk(
        sessionID: SessionID,
        languageHints: [String]
    ) async throws -> InsertResult {
        await events.append("transcription.start")
        return InsertResult(status: .noSpeech, method: .none, insertedText: "")
    }

    func cancel(sessionID: SessionID) async {
        await events.append("capture.cancel")
    }

    func setHandsFreeEnabled(_ enabled: Bool) async {
        await events.append("capture.ready")
    }

    func unloadTranscriptionRuntime() async {
        await events.append("runtime.unload")
    }

    func shutdown() async {
        await events.append("runtime.shutdown")
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
