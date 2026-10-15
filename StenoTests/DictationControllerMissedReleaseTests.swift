import Foundation
import Testing
@testable import Steno
@testable import StenoKit

/// The Option key as the system reports it, switched by the test.
@MainActor
private final class HeldOption {
    var isHeld = true
    /// How many times the controller has read the key's state.
    private(set) var reads = 0
    func read() -> Bool {
        reads += 1
        return isHeld
    }
}

@MainActor
@Suite("Missed Option release", .serialized)
struct DictationControllerMissedReleaseTests {
    private func controller(_ option: HeldOption, events: MediaReleaseEventLog) -> DictationController {
        makeTestDictationController(
            hotkey: MediaReleaseHotkeyService(),
            coordinator: MediaReleaseCoordinator(events: events),
            isOptionHeld: { option.read() }
        )
    }

    private func waitUntilRecording(_ controller: DictationController) async -> Bool {
        await eventuallyOnMain { controller.isRecording }
    }

    @Test("An Option recording whose key-up never arrives stops once the key is up, and is transcribed")
    func lostReleaseStops() async {
        let events = MediaReleaseEventLog()
        let option = HeldOption()
        let controller = controller(option, events: events)
        controller.pressToTalkStart()
        #expect(await waitUntilRecording(controller), "the recording never started")
        // The key comes up, but no release reaches the controller.
        option.isHeld = false
        #expect(await events.waitForCount("transcription.start", 1),
                "a recording with Option up was never stopped: \(events.names())")
        #expect(!controller.isRecording)
        await controller.teardownAndWait()
    }

    @Test("While Option stays down the recording keeps going")
    func heldKeepsRecording() async {
        let events = MediaReleaseEventLog()
        let option = HeldOption()
        let controller = controller(option, events: events)
        controller.pressToTalkStart()
        #expect(await waitUntilRecording(controller))
        // Several checks of the held key have run, however slowly they came.
        let readsAtStart = option.reads
        #expect(await eventuallyOnMain { option.reads >= readsAtStart + 3 })
        #expect(controller.isRecording, "a held Option recording was stopped")
        #expect(events.count("transcription.start") == 0)
        controller.pressToTalkStop()
        #expect(await events.waitForCount("transcription.start", 1))
        await controller.teardownAndWait()
    }
}
