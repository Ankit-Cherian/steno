import Foundation
import OSLog
import os
import StenoKit

/// Times each stage of a dictation in the unified log, as milliseconds since the key went down
/// and since recording stopped. Durations only: no words, apps or devices.
/// Read with: log show --last 10m --predicate 'subsystem == "io.stenoapp.steno" AND category == "Latency"'
enum DictationLatency {
    private static let logger = Logger(subsystem: "io.stenoapp.steno", category: "Latency")
    private static let marks = OSAllocatedUnfairLock<(start: TimeInterval?, stop: TimeInterval?)>(initialState: (nil, nil))

    @MainActor
    static func began() {
        MainThreadWatch.installOnce()
        let now = ProcessInfo.processInfo.systemUptime
        marks.withLock { $0 = (now, nil) }
        logger.notice("start")
        #if DEBUG
        sink.withLock { $0 }?("start", now)
        #endif
    }

    /// The shortest busy stretch worth logging. Benchmarks lower it to one frame.
    @MainActor static var busyThresholdMS = 50

    /// Starts the main-thread watch without a dictation, for benchmarks.
    @MainActor
    static func watchMainThread() { MainThreadWatch.installOnce() }

    /// A named moment, for benchmarks.
    static func note(_ what: StaticString) {
        logger.notice("\(what, privacy: .public)")
        #if DEBUG
        sink.withLock { $0 }?(what.description, ProcessInfo.processInfo.systemUptime)
        #endif
    }

    #if DEBUG
    /// Starts a tour step: first logs what the main thread spent since the previous step began,
    /// counting every busy stretch, then names the new step.
    @MainActor
    static func tourStep(_ name: String) {
        let t = MainThreadWatch.self
        logger.notice("tour total cpu \(t.tourCPU, privacy: .public) ms, \(t.tourInstructionsM, privacy: .public) Minstr, \(t.tourOver16, privacy: .public) over 16, \(t.tourOver50, privacy: .public) over 50, max \(t.tourMaxCPU, privacy: .public) ms")
        sink.withLock { $0 }?("tour total cpu \(t.tourCPU) ms, \(t.tourInstructionsM) Minstr, \(t.tourOver16) over 16, \(t.tourOver50) over 50, max \(t.tourMaxCPU) ms", ProcessInfo.processInfo.systemUptime)
        t.tourCPU = 0; t.tourInstructionsM = 0; t.tourOver16 = 0; t.tourOver50 = 0; t.tourMaxCPU = 0
        logger.notice("\(name, privacy: .public)")
    }

    /// Runs `body` without counting its main-thread time or instructions in the tour, for the
    /// tour's own work such as finding a control in the accessibility tree.
    @MainActor
    static func uncounted<T>(_ body: () throws -> T) rethrows -> T {
        let instructions = MainThreadWatch.instructions()
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        defer {
            MainThreadWatch.uncountedInstructions &+= MainThreadWatch.instructions() &- instructions
            MainThreadWatch.uncountedCPU &+= clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpu
        }
        return try body()
    }
    #endif

    /// Logs every stretch of `busyThresholdMS` (50 ms) or more that the main run loop spends busy,
    /// which is time the overlay, the window and the menu bar cannot update.
    @MainActor
    private enum MainThreadWatch {
        static var installed = false
        static var busySince: CFAbsoluteTime?
        static var cpuSince: UInt64 = 0
        #if DEBUG
        static var instructionsSince: UInt64 = 0

        /// Instructions retired by this process so far. Unlike time, the count does not grow when
        /// the machine is busy with other work, so two builds can be compared on a loaded Mac.
        /// Everything the main thread did since the last tour step, whatever the stretch length.
        static var tourCPU = 0, tourInstructionsM = 0, tourOver16 = 0, tourOver50 = 0, tourMaxCPU = 0
        /// The tour's own work inside the current busy stretch, taken off its totals.
        static var uncountedInstructions: UInt64 = 0, uncountedCPU: UInt64 = 0

        static func instructions() -> UInt64 {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
                }
            }
            return status == 0 ? info.ri_instructions : 0
        }
        #endif

        static func installOnce() {
            guard !installed else { return }
            installed = true
            let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
                MainActor.assumeIsolated {
                    let now = CFAbsoluteTimeGetCurrent()
                    if activity == .afterWaiting {
                        busySince = now
                        cpuSince = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                        #if DEBUG
                        instructionsSince = instructions()
                        uncountedInstructions = 0
                        uncountedCPU = 0
                        #endif
                    } else if let since = busySince {
                        busySince = nil
                        let busy = Int(((now - since) * 1000).rounded())
                        #if DEBUG
                        // CPU time is the busy stretch less any time the thread spent descheduled,
                        // so a loaded machine does not inflate a comparison between builds.
                        let spent = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpuSince
                        let retired = instructions() &- instructionsSince
                        let cpu = Int((spent &- min(uncountedCPU, spent)) / 1_000_000)
                        let instructionsM = Int((retired &- min(uncountedInstructions, retired)) / 1_000_000)
                        tourCPU += cpu
                        tourInstructionsM += instructionsM
                        if cpu >= 16 { tourOver16 += 1 }
                        if cpu >= 50 { tourOver50 += 1 }
                        tourMaxCPU = max(tourMaxCPU, cpu)
                        // A stretch that was mostly the tour's own work is not reported by its wall time.
                        if busy >= DictationLatency.busyThresholdMS, uncountedCPU == 0 || cpu >= DictationLatency.busyThresholdMS {
                            DictationLatency.logger.notice("main thread busy \(busy, privacy: .public) ms (cpu \(cpu, privacy: .public) ms, \(instructionsM, privacy: .public) Minstr)")
                            DictationLatency.sink.withLock { $0 }?("main thread busy \(busy) ms (cpu \(cpu) ms, \(instructionsM) Minstr)", ProcessInfo.processInfo.systemUptime)
                        }
                        #else
                        if busy >= DictationLatency.busyThresholdMS {
                            let cpu = Int((clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpuSince) / 1_000_000)
                            DictationLatency.logger.notice("main thread busy \(busy, privacy: .public) ms (cpu \(cpu, privacy: .public) ms)")
                        }
                        #endif
                    }
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    static func stopped() {
        let now = ProcessInfo.processInfo.systemUptime
        let start = marks.withLock { state -> TimeInterval? in
            state.stop = now
            return state.start
        }
        logger.notice("stop at +\(Self.ms(start, now), privacy: .public) ms")
        #if DEBUG
        sink.withLock { $0 }?("stop", now)
        #endif
    }

    /// A stage after the start.
    static func mark(_ stage: StaticString) {
        let now = ProcessInfo.processInfo.systemUptime
        let (start, stop) = marks.withLock { ($0.start, $0.stop) }
        if let stop {
            logger.notice("\(stage, privacy: .public) +\(Self.ms(stop, now), privacy: .public) ms after stop")
        } else {
            logger.notice("\(stage, privacy: .public) +\(Self.ms(start, now), privacy: .public) ms after start")
        }
        #if DEBUG
        sink.withLock { $0 }?(stage.description, now)
        #endif
    }

    /// How long loading Core Audio's component list took at launch. When the system's component
    /// registrar was not running this is where its start-up goes, instead of the first press.
    static func audioComponentsLoaded(in duration: Duration) {
        let ms = Int((Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000).rounded())
        logger.notice("audio components loaded in \(ms, privacy: .public) ms")
    }

    /// A step of the pipeline after the stop, named as the log shows it.
    static func step(_ step: DictationStep) {
        switch step {
        case .captureClosed: mark("capture closed")
        case .transcriptionStarted: mark("transcription started")
        case .helperRequested: mark("helper requested")
        case .helperReplied: mark("helper replied")
        case .artifactsStripped: mark("artifacts stripped")
        case .transcribed: mark("transcribed")
        case .cleanedUp: mark("cleaned up")
        case .inserted: mark("inserted")
        case .historySaved: mark("history saved")
        case .usageRecorded: mark("usage recorded")
        }
    }

    #if DEBUG
    /// Receives each mark's name and uptime as well as the log, for the pipeline benchmark.
    static let sink = OSAllocatedUnfairLock<(@Sendable (String, TimeInterval) -> Void)?>(initialState: nil)
    #endif

    private static func ms(_ from: TimeInterval?, _ to: TimeInterval) -> Int {
        guard let from else { return -1 }
        return Int(((to - from) * 1000).rounded())
    }
}
