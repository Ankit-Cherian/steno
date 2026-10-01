import AppKit
import Foundation
import Testing
@testable import Steno
@testable import StenoKit

// Drives the production MacMediaInterruptionService through the real
// DictationController with a scripted media driver.

@MainActor
@Test("Quitting right after key-up still resumes the media Steno paused")
func quitRightAfterKeyUpReleasesMedia() async {
    let harness = MediaReleaseHarness(
        snapshots: Array(repeating: playingPodcasts(), count: 40),
        snapshotDelayMilliseconds: 0
    )
    let controller = harness.controller
    let events = harness.events

    controller.pressToTalkStart()
    guard await events.waitForCount("media.begin.token", 1) else {
        Issue.record("No pause ownership: \(events.names())")
        await controller.teardownAndWait()
        return
    }
    // Key-up and quit land in the same main-actor turn, before the stop
    // task has run.
    controller.pressToTalkStop()
    await controller.teardownAndWait()

    #expect(harness.media.begunTokens.count == 1)
    #expect(harness.media.endedTokens == harness.media.begunTokens)
    #expect(harness.driver.commands.first == .pause)
    #expect(harness.driver.commands.filter { $0 == .play }.count == 1)
}

@MainActor
@Test("Stopping does not wait for an unanswered media Pause, and the late Pause is still resumed")
func stopDoesNotWaitForUnansweredPause() async {
    let events = MediaReleaseEventLog()
    let driver = SlowPauseMediaDriver(events: events, pauseAcknowledgementDelay: .milliseconds(900))
    let service = MacMediaInterruptionService(
        driver: driver,
        verificationDelays: MacMediaInterruptionService.defaultVerificationDelays,
        resumeVerificationDelays: productionResumeDelays,
        sleep: { try? await Task.sleep(nanoseconds: $0) },
        systemSupportsMediaPausing: true
    )
    let media = ObservedMediaService(inner: service, events: events)
    let controller = makeTestDictationController(
        hotkey: MediaReleaseHotkeyService(),
        mediaInterruption: media,
        coordinator: MediaReleaseCoordinator(events: events)
    )

    controller.pressToTalkStart()
    guard await events.waitForCount("media.command.pause", 1) else {
        Issue.record("Pause was never sent: \(events.names())")
        await controller.teardownAndWait()
        return
    }
    try? await Task.sleep(for: .milliseconds(200))
    let keyUp = ContinuousClock.now
    controller.pressToTalkStop()

    #expect(await events.waitForCount("transcription.start", 1))
    if let transcribedAt = events.instant(of: "transcription.start") {
        let wait = transcribedAt - keyUp
        #expect(wait < .milliseconds(300), "Transcription waited \(wait) after key-up: \(events.names())")
    }
    // The Pause was still unanswered when transcription began.
    #expect(events.index(of: "transcription.start")! < events.index(of: "media.pause.acknowledged")
        ?? Int.max)

    // Once the Pause is accepted, Steno owns that pause and resumes exactly
    // that app, once.
    #expect(await events.waitForCount("media.pause.acknowledged", 1))
    #expect(await events.waitForCount("media.release.end", 1))
    #expect(await events.waitForCount("media.command.play", 1))
    #expect(media.begunTokens.count == 1)
    #expect(media.endedTokens == media.begunTokens)
    #expect(driver.commands == [.pause, .play])
    #expect(driver.playedApplications == [["com.apple.podcasts"]])
    await controller.teardownAndWait()
}

/// Answers Pause only after a delay, like a player that is slow to acknowledge.
@MainActor
final class SlowPauseMediaDriver: MediaInterruptionDriving {
    private let events: MediaReleaseEventLog
    private let pauseAcknowledgementDelay: Duration
    private(set) var commands: [SemanticMediaCommand] = []
    private(set) var playedApplications: [[String]] = []

    init(events: MediaReleaseEventLog, pauseAcknowledgementDelay: Duration) {
        self.events = events
        self.pauseAcknowledgementDelay = pauseAcknowledgementDelay
    }

    func snapshot() async -> MediaInterruptionSnapshot {
        playingPodcasts()
    }

    func sendPause(to destination: MediaPauseDestination) async -> MediaCommandDispatchResult {
        await acknowledgePause(destination.applicationBundleIdentifiers)
    }

    func sendPause(to destination: VerifiedMediaResumeDestination) async -> MediaCommandDispatchResult {
        await acknowledgePause(destination.applicationBundleIdentifiers)
    }

    func sendPlay(to destination: VerifiedMediaResumeDestination) async -> MediaCommandDispatchResult {
        commands.append(.play)
        playedApplications.append(destination.applicationBundleIdentifiers)
        events.append("media.command.play")
        return MediaCommandDispatchResult(
            acceptedApplicationBundleIdentifiers: destination.applicationBundleIdentifiers
        )
    }

    private func acknowledgePause(_ applications: [String]) async -> MediaCommandDispatchResult {
        commands.append(.pause)
        events.append("media.command.pause")
        try? await Task.sleep(for: pauseAcknowledgementDelay)
        events.append("media.pause.acknowledged")
        return MediaCommandDispatchResult(acceptedApplicationBundleIdentifiers: applications)
    }
}
