import Foundation
import Testing
@testable import StenoKit

@Suite("Input level mapping")
struct InputLevelMappingTests {
    @Test("Silence and anything below the noise floor read exactly zero", arguments: [
        Float(-160), -120, -80, -50.0001, -50,
    ])
    func silenceIsZero(decibels: Float) {
        #expect(InputLevelMapping.standard.level(forDecibels: decibels) == 0)
    }

    @Test("Full scale and clipping read exactly one", arguments: [Float(-10), -3, 0, 6])
    func clippingIsOne(decibels: Float) {
        #expect(InputLevelMapping.standard.level(forDecibels: decibels) == 1)
    }

    @Test("Unreadable values never show a level")
    func unreadableValues() {
        let mapping = InputLevelMapping.standard
        #expect(mapping.level(forDecibels: .nan) == 0)
        #expect(mapping.level(forDecibels: -.infinity) == 0)
        #expect(mapping.level(forDecibels: .infinity) == 1)
    }

    @Test("Louder input never reads lower")
    func monotonic() {
        let mapping = InputLevelMapping.standard
        var previous: Float = 0
        for step in 0...200 {
            let decibels = -70 + Float(step) * 0.4
            let level = mapping.level(forDecibels: decibels)
            #expect(level >= previous, "at \(decibels) dB")
            #expect((0...1).contains(level))
            previous = level
        }
        #expect(mapping.level(forDecibels: -30) == 0.5)
    }
}

@Suite("Input level smoothing")
struct InputLevelSmootherTests {
    @Test("A rise reaches about two thirds of the target in 30 ms")
    func attack() {
        var smoother = InputLevelSmoother()
        var level: Float = 0
        for _ in 0..<30 { level = smoother.update(target: 1, elapsed: 0.001) }
        #expect(abs(level - 0.632) < 0.01)
        for _ in 0..<120 { level = smoother.update(target: 1, elapsed: 0.001) }
        #expect(level > 0.99)
    }

    @Test("A fall keeps about a third of the level after 200 ms")
    func release() {
        var smoother = InputLevelSmoother()
        _ = smoother.update(target: 1, elapsed: 10)
        var level: Float = 1
        for _ in 0..<200 { level = smoother.update(target: 0.0001, elapsed: 0.001) }
        #expect(abs(level - 0.368) < 0.01)
    }

    @Test("The same step is the same whether polled at 30 Hz or 60 Hz")
    func independentOfPollingRate() {
        var slow = InputLevelSmoother()
        var fast = InputLevelSmoother()
        for _ in 0..<3 { _ = slow.update(target: 0.8, elapsed: 1.0 / 30) }
        for _ in 0..<6 { _ = fast.update(target: 0.8, elapsed: 1.0 / 60) }
        #expect(abs(slow.value - fast.value) < 0.0001)
    }

    @Test("Silence after speech settles to exactly zero")
    func settlesToZero() {
        var smoother = InputLevelSmoother()
        _ = smoother.update(target: 1, elapsed: 10)
        var ticks = 0
        while smoother.value != 0 && ticks < 60 {
            _ = smoother.update(target: 0, elapsed: 1.0 / 30)
            ticks += 1
        }
        #expect(smoother.value == 0)
        // About one second of silence at 30 Hz.
        #expect(ticks <= 30)
    }

    @Test("No elapsed time changes nothing")
    func zeroElapsed() {
        var smoother = InputLevelSmoother()
        #expect(smoother.update(target: 1, elapsed: 0) == 0)
    }
}

@MainActor
@Suite("Input level meter")
struct InputLevelMeterTests {
    @Test("The meter reads nothing until a capture starts it")
    func idleMeterNeverSamples() {
        let meter = InputLevelMeter(schedulesTimer: false)
        let levels = LevelLog()
        meter.onLevel = { levels.append($0) }
        meter.tick(now: 1)
        #expect(!meter.isRunning)
        #expect(levels.values.isEmpty)
    }

    @Test("A running meter maps, smooths and delivers each reading")
    func deliversSmoothedLevels() {
        let meter = InputLevelMeter(schedulesTimer: false)
        let levels = LevelLog()
        meter.onLevel = { levels.append($0) }
        var samples = 0
        meter.start { samples += 1; return -10 }
        #expect(meter.isRunning)
        meter.tick(now: 10)
        meter.tick(now: 10 + 1.0 / 30)
        #expect(samples == 2)
        #expect(levels.values.count == 2)
        #expect(levels.values[0] > 0 && levels.values[0] < levels.values[1])
        #expect(levels.values[1] <= 1)
    }

    @Test("Silence while running delivers zero once, not every tick")
    func silenceDeliversZeroOnce() {
        let meter = InputLevelMeter(schedulesTimer: false)
        let levels = LevelLog()
        meter.onLevel = { levels.append($0) }
        meter.start { -160 }
        for tick in 0..<10 { meter.tick(now: Double(tick) / 30) }
        #expect(levels.values.isEmpty)
        meter.stop()
        #expect(levels.values == [0])
    }

    @Test("Stopping resets to zero at once and ends sampling")
    func stopResetsToZero() {
        let meter = InputLevelMeter(schedulesTimer: false)
        let levels = LevelLog()
        meter.onLevel = { levels.append($0) }
        var samples = 0
        meter.start { samples += 1; return 0 }
        meter.tick(now: 1)
        meter.tick(now: 1.1)
        meter.stop()
        #expect(!meter.isRunning)
        #expect(levels.values.last == 0)
        let count = levels.values.count
        meter.tick(now: 1.2)
        #expect(samples == 2)
        #expect(levels.values.count == count)
        // A second stop is quiet.
        meter.stop()
        #expect(levels.values.count == count)
    }

    @Test("A restarted meter rises from zero, not from the last capture's level")
    func restartStartsFromZero() {
        let meter = InputLevelMeter(schedulesTimer: false)
        let levels = LevelLog()
        meter.onLevel = { levels.append($0) }
        meter.start { 0 }
        meter.tick(now: 1)
        meter.tick(now: 2)
        meter.stop()
        levels.removeAll()
        meter.start { 0 }
        meter.tick(now: 3)
        meter.tick(now: 3 + 1.0 / 30)
        #expect(levels.values.first.map { $0 < 0.9 } == true)
    }

    @Test("Levels are delivered on the main thread")
    func deliversOnMain() async {
        let meter = InputLevelMeter()
        let delivered = LevelLog()
        meter.onLevel = { level in
            delivered.append(Thread.isMainThread ? level : -1)
        }
        // Alternating loud and silent input changes the level on every tick, so
        // each tick delivers one however late the timer fires. A steady input
        // reaches its level in fewer ticks when they come late, and repeats are
        // not delivered.
        var loud = false
        meter.start {
            loud.toggle()
            return loud ? 0 : -90
        }
        #expect(await eventually { delivered.values.count >= 3 })
        meter.stop()
        #expect(!delivered.values.contains(-1))
    }
}

final class LevelLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []

    var values: [Float] { lock.withLock { storage } }

    func append(_ value: Float) {
        lock.withLock { storage.append(value) }
    }

    func removeAll() {
        lock.withLock { storage.removeAll() }
    }
}
