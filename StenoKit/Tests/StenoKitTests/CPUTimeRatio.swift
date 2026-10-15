import Foundation

/// CPU time the calling thread spent in `body`. Unlike wall time it leaves out
/// the time the thread waited for a core, so other work on the machine barely
/// moves it. Returns nil when `body` resumed on another thread, which would
/// leave part of its work uncounted.
func threadCPUTime(_ body: () async throws -> Void) async rethrows -> Duration? {
    let thread = pthread_self()
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    try await body()
    let end = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    guard pthread_equal(thread, pthread_self()) != 0 else { return nil }
    return .nanoseconds(Int64(end - start))
}

/// How many times longer `large` takes than `small`, comparing the fastest of
/// `runs` alternating runs of each, so both see the same machine. Infinite if
/// no run of either stayed on one thread.
func cpuTimeRatio(
    runs: Int = 7,
    small: () async throws -> Void,
    large: () async throws -> Void
) async rethrows -> Double {
    var fastestSmall: Duration?
    var fastestLarge: Duration?
    for _ in 0..<runs {
        if let time = try await threadCPUTime(small) { fastestSmall = min(fastestSmall ?? time, time) }
        if let time = try await threadCPUTime(large) { fastestLarge = min(fastestLarge ?? time, time) }
    }
    guard let fastestSmall, let fastestLarge, fastestSmall > .zero else { return .infinity }
    return fastestLarge / fastestSmall
}
