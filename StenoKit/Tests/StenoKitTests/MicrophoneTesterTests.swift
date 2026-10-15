#if os(macOS)
import CoreAudio
import Foundation
import Testing
@testable import StenoKit

@MainActor
@Suite("Microphone test")
struct MicrophoneTesterTests {
    @Test("A test refuses to start while a dictation is active and opens nothing")
    func refusesDuringDictation() {
        let fixture = TesterFixture()
        fixture.dictationActive = true
        #expect(throws: MicrophoneTestError.dictationActive) {
            try fixture.tester.start(deviceID: nil)
        }
        #expect(fixture.sources.isEmpty)
        #expect(!fixture.tester.isRunning)
        #expect(!fixture.meter.isRunning)
    }

    @Test("A running test delivers levels and stopping ends at zero")
    func deliversLevels() throws {
        let fixture = TesterFixture()
        var levels: [Float] = []
        var stops = 0
        fixture.tester.onLevel = { levels.append($0) }
        fixture.tester.onStop = { stops += 1 }

        try fixture.tester.start(deviceID: nil)
        let source = try #require(fixture.sources.last)
        #expect(source.isRunning)
        #expect(fixture.tester.isRunning)
        source.currentDecibels = -20
        fixture.meter.tick(now: 1)
        #expect(levels.last.map { $0 > 0 } == true)

        fixture.tester.stop()
        #expect(!source.isRunning)
        #expect(!fixture.tester.isRunning)
        #expect(levels.last == 0)
        #expect(stops == 1)
        fixture.tester.stop()
        #expect(stops == 1)
    }

    @Test("A test stops by itself after its time limit")
    func autoStops() async throws {
        let fixture = TesterFixture(autoStopDelay: .milliseconds(50))
        var stopped = false
        fixture.tester.onStop = { stopped = true }
        try fixture.tester.start(deviceID: nil)
        let source = try #require(fixture.sources.last)
        // Counted turns, not a clock: after a stall of the whole test process a clock deadline
        // could pass before the stop gets its turn on the main actor.
        for _ in 0..<500 where !stopped {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(stopped)
        #expect(!source.isRunning)
        #expect(!fixture.meter.isRunning)
    }

    @Test("The time limit is five seconds")
    func limitIsFiveSeconds() {
        #expect(MacMicrophoneTester.maximumDuration == .seconds(5))
    }

    @Test("An earlier test's timer does not stop a newer test")
    func restartKeepsNewTimer() async throws {
        let timers = HeldTimers()
        let fixture = TesterFixture(sleep: timers.sleep)
        try fixture.tester.start(deviceID: nil)
        try fixture.tester.start(deviceID: nil)
        #expect(fixture.sources.count == 2)
        #expect(!fixture.sources[0].isRunning)
        #expect(await eventuallyOnMain { timers.count == 2 })

        // The first test's timer comes due while the second test runs.
        timers.fire(0)
        await Task.yield()
        await Task.yield()
        #expect(fixture.sources[1].isRunning)

        // The second test's own timer still ends it.
        timers.fire(1)
        #expect(await eventuallyOnMain { !fixture.sources[1].isRunning })
    }

    @Test("A chosen device is tested; a missing one falls back to the system input")
    func deviceChoice() throws {
        let fixture = TesterFixture()
        fixture.connected = ["usb": 9]

        try fixture.tester.start(deviceID: "usb")
        #expect(fixture.sourceDevices.last == .some(9))
        #expect(fixture.tester.selection == .device(id: "usb"))
        fixture.tester.stop()

        try fixture.tester.start(deviceID: "gone")
        #expect(fixture.sourceDevices.last == .some(nil))
        #expect(fixture.tester.selection == .missing(id: "gone"))
        fixture.tester.stop()

        try fixture.tester.start(deviceID: nil)
        #expect(fixture.sourceDevices.last == .some(nil))
        #expect(fixture.tester.selection == .systemInput)
        fixture.tester.stop()
    }

    @Test("An input that cannot start is reported and leaves nothing running")
    func sourceFailure() {
        let fixture = TesterFixture()
        fixture.sourcesFail = true
        #expect(throws: MicrophoneTestError.microphoneUnavailable) {
            try fixture.tester.start(deviceID: nil)
        }
        #expect(!fixture.tester.isRunning)
        #expect(!fixture.meter.isRunning)
    }

    @Test("An input that ends by itself, such as an unplugged microphone, ends the test")
    func sourceEnds() throws {
        let fixture = TesterFixture()
        var stopped = false
        fixture.tester.onStop = { stopped = true }
        try fixture.tester.start(deviceID: nil)
        fixture.sources.last?.endByItself()
        #expect(stopped)
        #expect(!fixture.tester.isRunning)
    }

    @Test("The production level source only measures; it has no file to write")
    func levelSourceWritesNothing() {
        // The test's source type takes no URL and no writer, so it cannot
        // record to disk. This holds the shape in place.
        let source: any MicrophoneLevelSource = EngineMicrophoneLevelSource(deviceID: nil)
        #expect(source.currentDecibels == nil)
        #expect(!source.isRunning)
    }
}

@MainActor
private final class TesterFixture {
    var dictationActive = false
    var connected: [String: AudioDeviceID] = [:]
    var sourcesFail = false
    var sources: [FakeLevelSource] = []
    var sourceDevices: [AudioDeviceID?] = []
    let meter = InputLevelMeter(schedulesTimer: false)
    private(set) var tester: MacMicrophoneTester!

    init(
        autoStopDelay: Duration = .seconds(60),
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        tester = MacMicrophoneTester(
            isDictationActive: { [unowned self] in self.dictationActive },
            makeSource: { [unowned self] deviceID in
                let source = FakeLevelSource(fails: self.sourcesFail)
                self.sources.append(source)
                self.sourceDevices.append(deviceID)
                return source
            },
            resolveDevice: { [unowned self] uid in self.connected[uid] },
            meter: meter,
            autoStopDelay: autoStopDelay,
            sleep: sleep
        )
    }
}

@MainActor
private final class FakeLevelSource: MicrophoneLevelSource {
    let fails: Bool
    var currentDecibels: Float?
    var onEndedByItself: (@MainActor () -> Void)?
    private(set) var isRunning = false

    init(fails: Bool) {
        self.fails = fails
    }

    func start() throws {
        if fails { throw PinnedAudioInputError.deviceUnavailable }
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func endByItself() {
        isRunning = false
        onEndedByItself?()
    }
}

/// Auto-stop timers that come due only when the test fires them, in any order.
@MainActor
private final class HeldTimers {
    private var pending: [CheckedContinuation<Void, Never>?] = []
    var count: Int { pending.count }

    var sleep: @MainActor (Duration) async -> Void {
        { [self] _ in await withCheckedContinuation { pending.append($0) } }
    }

    func fire(_ index: Int) {
        pending[index]?.resume()
        pending[index] = nil
    }
}
#endif
