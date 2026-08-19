import Foundation
import Testing
@testable import StenoBenchmarkCore

@Test("Bounded allocator sawtooth is not reported as unbounded growth")
func boundedAllocatorSawtoothIsNotUnbounded() {
    let mebibyte = UInt64(1_048_576)
    let checkpoints: [(Int, UInt64)] = [
        (1, 1_800 * mebibyte),
        (25, 1_812 * mebibyte),
        (50, 1_802 * mebibyte),
        (75, 1_813 * mebibyte),
        (100, 1_803 * mebibyte),
        (125, 1_812 * mebibyte),
        (150, 1_803 * mebibyte),
        (175, 1_813 * mebibyte),
        (200, 1_803 * mebibyte),
        (225, 1_812 * mebibyte),
        (250, 1_803 * mebibyte),
    ]

    #expect(!LiveContextBenchmarkRunner.detectsUnboundedSawtooth(
        checkpoints,
        maximumTailSlopeBytesPerRequest: 32 * 1_024
    ))
}

@Test("Rising sawtooth envelope remains blocking")
func risingSawtoothEnvelopeIsUnbounded() {
    let mebibyte = UInt64(1_048_576)
    let checkpoints: [(Int, UInt64)] = [
        (1, 1_800 * mebibyte),
        (25, 1_812 * mebibyte),
        (50, 1_804 * mebibyte),
        (75, 1_824 * mebibyte),
        (100, 1_816 * mebibyte),
        (125, 1_836 * mebibyte),
        (150, 1_828 * mebibyte),
        (175, 1_848 * mebibyte),
        (200, 1_840 * mebibyte),
        (225, 1_860 * mebibyte),
        (250, 1_852 * mebibyte),
    ]

    #expect(LiveContextBenchmarkRunner.detectsUnboundedSawtooth(
        checkpoints,
        maximumTailSlopeBytesPerRequest: 32 * 1_024
    ))
}

@Test("Sawtooth analysis uses the latter half by request index, not checkpoint count")
func sawtoothTailUsesRequestMidpoint() {
    let mebibyte = UInt64(1_048_576)
    let checkpoints: [(Int, UInt64)] = [
        (1, 1_800 * mebibyte),
        (100, 1_800 * mebibyte),
        (200, 1_800 * mebibyte),
        (250, 1_800 * mebibyte),
        (275, 1_820 * mebibyte),
        (300, 1_812 * mebibyte),
        (325, 1_832 * mebibyte),
        (350, 1_824 * mebibyte),
        (375, 1_844 * mebibyte),
        (400, 1_836 * mebibyte),
        (425, 1_836 * mebibyte),
        (450, 1_836 * mebibyte),
        (475, 1_836 * mebibyte),
        (500, 1_836 * mebibyte),
    ]

    #expect(LiveContextBenchmarkRunner.detectsUnboundedSawtooth(
        checkpoints,
        maximumTailSlopeBytesPerRequest: 32 * 1_024
    ))
}

@Test("Sawtooth evidence fails closed when there are too few checkpoints")
func sawtoothEvidenceNeedsEnoughCheckpoints() {
    #expect(LiveContextBenchmarkRunner.detectsUnboundedSawtooth(
        [(1, 100), (25, 200), (50, 150), (75, 250)],
        maximumTailSlopeBytesPerRequest: 32 * 1_024
    ))
}

@Test("Helper monitor continuity keeps the 250 millisecond fail-closed boundary")
func helperMonitorContinuityBoundary() {
    #expect(LiveContextBenchmarkRunner.helperMonitorIsContinuous(
        observationCount: 500,
        unexpectedObservationCount: 0,
        maximumGapMS: 250,
        maximumAllowedGapMS: 250,
        preSoakObservationLeadMS: 0,
        postSoakObservationLagMS: 0
    ))
    #expect(!LiveContextBenchmarkRunner.helperMonitorIsContinuous(
        observationCount: 500,
        unexpectedObservationCount: 0,
        maximumGapMS: 250.001,
        maximumAllowedGapMS: 250,
        preSoakObservationLeadMS: 0,
        postSoakObservationLagMS: 0
    ))
    #expect(!LiveContextBenchmarkRunner.helperMonitorIsContinuous(
        observationCount: 1,
        unexpectedObservationCount: 0,
        maximumGapMS: 50,
        maximumAllowedGapMS: 250,
        preSoakObservationLeadMS: 0,
        postSoakObservationLagMS: 0
    ))
    #expect(!LiveContextBenchmarkRunner.helperMonitorIsContinuous(
        observationCount: 500,
        unexpectedObservationCount: 0,
        maximumGapMS: .infinity,
        maximumAllowedGapMS: 250,
        preSoakObservationLeadMS: 0,
        postSoakObservationLagMS: 0
    ))
    #expect(!LiveContextBenchmarkRunner.helperMonitorIsContinuous(
        observationCount: 500,
        unexpectedObservationCount: 1,
        maximumGapMS: 50,
        maximumAllowedGapMS: 250,
        preSoakObservationLeadMS: 0,
        postSoakObservationLagMS: 0
    ))
    #expect(!LiveContextBenchmarkRunner.helperMonitorIsContinuous(
        observationCount: 500,
        unexpectedObservationCount: 0,
        maximumGapMS: 50,
        maximumAllowedGapMS: 250,
        preSoakObservationLeadMS: -0.001,
        postSoakObservationLagMS: 0
    ))
    #expect(!LiveContextBenchmarkRunner.helperMonitorIsContinuous(
        observationCount: 500,
        unexpectedObservationCount: 0,
        maximumGapMS: 50,
        maximumAllowedGapMS: 250,
        preSoakObservationLeadMS: 0,
        postSoakObservationLagMS: -0.001
    ))
    #expect(!LiveContextBenchmarkRunner.helperMonitorIsContinuous(
        observationCount: 500,
        unexpectedObservationCount: 0,
        maximumGapMS: 50,
        maximumAllowedGapMS: 250,
        preSoakObservationLeadMS: 250.001,
        postSoakObservationLagMS: 0
    ))
    #expect(!LiveContextBenchmarkRunner.helperMonitorIsContinuous(
        observationCount: 500,
        unexpectedObservationCount: 0,
        maximumGapMS: 50,
        maximumAllowedGapMS: 250,
        preSoakObservationLeadMS: 0,
        postSoakObservationLagMS: 250.001
    ))
}

@Test("Helper monitor maximum gap includes the terminal interval")
func helperMonitorGapIncludesTerminalInterval() {
    #expect(LiveContextBenchmarkRunner.maximumHelperMonitorGapMS(
        observationTimestampsNanos: [0, 50_000_000],
        observationEndNanos: 300_000_000
    ) == 250)
    #expect(LiveContextBenchmarkRunner.maximumHelperMonitorGapMS(
        observationTimestampsNanos: [100_000_000],
        observationEndNanos: 50_000_000
    ).isInfinite)
}

@Test("Identity manifest material binds the helper-monitor gap threshold")
func manifestBindsHelperMonitorGapThreshold() {
    let required = LiveContextBenchmarkRunner.manifestThresholdComponents(.required)
    var changed = LiveContextBenchmarkThresholds.required
    changed.maximumHelperMonitorGapMS = 249
    let altered = LiveContextBenchmarkRunner.manifestThresholdComponents(changed)

    #expect(required.count == 14)
    #expect(required != altered)
    #expect(required.dropLast() == altered.dropLast())
}

@Test("Helper discovery uses the benchmark process's direct children")
func helperDiscoveryFindsDirectChild() async throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["2"]
    try child.run()
    defer {
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
    }

    var observed: [Int32] = []
    for _ in 0..<20 where observed.isEmpty {
        observed = LiveContextProcessProbe.childProcessIDs(named: "sleep")
        if observed.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    }
    #expect(observed.contains(child.processIdentifier))
}
