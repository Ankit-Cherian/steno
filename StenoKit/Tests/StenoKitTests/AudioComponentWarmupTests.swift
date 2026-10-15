#if os(macOS)
import Foundation
import Testing
@testable import StenoKit

@Suite("Audio component warm-up")
struct AudioComponentWarmupTests {
    @Test("The lookup runs once, off the main thread, and the main actor stays free while it waits")
    @MainActor
    func runsOffTheMainThread() async {
        let calls = LookupCalls()
        let mainActorTurn = DispatchSemaphore(value: 0)
        let warmup = Task {
            await AudioComponentWarmup.run {
                calls.record(onMainThread: Thread.isMainThread)
                // Only the main actor ends this wait, so it finishes only if the
                // main actor is free while the lookup is running.
                calls.recordReleased(mainActorTurn.wait(timeout: .now() + .seconds(120)) == .success)
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        #expect(await eventuallyOnMain { calls.count == 1 })
        mainActorTurn.signal()

        let elapsed = await warmup.value
        #expect(calls.count == 1)
        #expect(calls.anyOnMainThread == false)
        #expect(calls.wasReleasedByMainActor)
        #expect(elapsed >= .milliseconds(200))
    }

    @Test("The system lists audio components without any device being opened")
    func listsComponents() {
        #expect(AudioComponentWarmup.componentCount() > 0)
    }
}

private final class LookupCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Bool] = []
    func record(onMainThread: Bool) { lock.withLock { calls.append(onMainThread) } }
    var count: Int { lock.withLock { calls.count } }
    var anyOnMainThread: Bool { lock.withLock { calls.contains(true) } }
    private var released = false
    func recordReleased(_ value: Bool) { lock.withLock { released = value } }
    var wasReleasedByMainActor: Bool { lock.withLock { released } }
}
#endif
