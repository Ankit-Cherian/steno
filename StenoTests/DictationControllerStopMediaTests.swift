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
