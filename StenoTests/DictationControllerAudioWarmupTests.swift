import Foundation
import Testing
@testable import Steno
@testable import StenoKit

@Suite("Audio components load at launch", .serialized)
@MainActor
struct DictationControllerAudioWarmupTests {
    @Test("The controller starts loading audio components off the main thread and does not wait for it")
    func warmupStartsWithoutBlocking() async throws {
        let probe = WarmupProbe()
        let lookupMayFinish = DispatchSemaphore(value: 0)
        let controller = makeTestDictationController(
            hotkey: TranscriptionCancelHotkey(),
            audioComponentWarmup: {
                probe.began(onMainThread: pthread_main_np() != 0)
                // Blocks its thread, as the registrar lookup does, until the test
                // has the controller.
                blockThread(until: lookupMayFinish)
                probe.finished()
                return .milliseconds(300)
            }
        )
        // Creating the controller returned while the lookup could not have finished.
        #expect(!probe.isFinished, "creating the controller waited for the warm-up")
        lookupMayFinish.signal()
        #expect(await cancelTestEventually { probe.calls == 1 })
        #expect(probe.ranOnMainThread == false)
        #expect(await cancelTestEventually { probe.isFinished })
        #expect(probe.calls == 1)
        controller.teardown()
    }
}

/// Blocks the calling thread until `semaphore` is signalled; the bound only stops a defect hanging the run.
private func blockThread(until semaphore: DispatchSemaphore) {
    _ = semaphore.wait(timeout: .now() + .seconds(120))
}

private final class WarmupProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var onMain = false
    private var done = false
    func began(onMainThread: Bool) { lock.withLock { callCount += 1; onMain = onMain || onMainThread } }
    func finished() { lock.withLock { done = true } }
    var calls: Int { lock.withLock { callCount } }
    var ranOnMainThread: Bool { lock.withLock { onMain } }
    var isFinished: Bool { lock.withLock { done } }
}
