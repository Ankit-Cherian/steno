import CryptoKit
#if os(macOS)
import Darwin
#endif
import Foundation
import StenoKit

// MARK: - Aggregate artifact

public struct WarmRuntimeLatencySummary: Sendable, Codable, Equatable {
    public var count: Int
    public var meanMS: Double?
    public var p50MS: Double?
    public var p90MS: Double?
    public var p99MS: Double?
    public var meanRTF: Double?

    public init(
        count: Int,
        meanMS: Double?,
        p50MS: Double?,
        p90MS: Double?,
        p99MS: Double?,
        meanRTF: Double?
    ) {
        self.count = count
        self.meanMS = meanMS
        self.p50MS = p50MS
        self.p90MS = p90MS
        self.p99MS = p99MS
        self.meanRTF = meanRTF
    }
}

public enum WarmRuntimeDistribution {
    public static func summarize(
        milliseconds: [Double],
        audioDurationMilliseconds: [Int?] = []
    ) -> WarmRuntimeLatencySummary {
        let rtfs = zip(milliseconds, audioDurationMilliseconds).compactMap { elapsed, audioDuration -> Double? in
            guard let audioDuration, audioDuration > 0 else { return nil }
            return elapsed / Double(audioDuration)
        }
        return WarmRuntimeLatencySummary(
            count: milliseconds.count,
            meanMS: mean(milliseconds),
            p50MS: percentile(milliseconds, percentile: 0.50),
            p90MS: percentile(milliseconds, percentile: 0.90),
            p99MS: percentile(milliseconds, percentile: 0.99),
            meanRTF: mean(rtfs)
        )
    }

    static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func percentile(_ values: [Double], percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let bounded = min(max(percentile, 0), 1)
        let rank = Int(ceil(bounded * Double(sorted.count))) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

public struct WarmRuntimeParitySummary: Sendable, Codable, Equatable {
    public var baselineCount: Int
    public var retainedCount: Int
    public var comparisons: Int
    public var textMatches: Int
    public var segmentMatches: Int
    public var confidenceMatches: Int
    public var durationMatches: Int
    public var maximumConfidenceDelta: Double?

    public init(
        comparisons: Int,
        textMatches: Int,
        segmentMatches: Int,
        confidenceMatches: Int,
        durationMatches: Int,
        maximumConfidenceDelta: Double?,
        baselineCount: Int? = nil,
        retainedCount: Int? = nil
    ) {
        self.baselineCount = baselineCount ?? comparisons
        self.retainedCount = retainedCount ?? comparisons
        self.comparisons = comparisons
        self.textMatches = textMatches
        self.segmentMatches = segmentMatches
        self.confidenceMatches = confidenceMatches
        self.durationMatches = durationMatches
        self.maximumConfidenceDelta = maximumConfidenceDelta
    }

    public var allContractsMatch: Bool {
        comparisons > 0
            && !countMismatch
            && textMatches == comparisons
            && segmentMatches == comparisons
            && confidenceMatches == comparisons
            && durationMatches == comparisons
    }

    public var countMismatch: Bool {
        baselineCount != retainedCount
    }

    public static func compare(
        baseline: [RawTranscript],
        retained: [RawTranscript],
        confidenceTolerance: Double = 0.000_001
    ) -> WarmRuntimeParitySummary {
        let pairs = Array(zip(baseline, retained))
        var textMatches = 0
        var segmentMatches = 0
        var matchingConfidenceContracts = 0
        var durationMatches = 0
        var maximumConfidenceDelta: Double?

        for (expected, actual) in pairs {
            if expected.text == actual.text { textMatches += 1 }
            if segmentsMatch(expected.segments, actual.segments) { segmentMatches += 1 }
            if confidenceMatches(
                expected: expected,
                actual: actual,
                tolerance: confidenceTolerance,
                maximumDelta: &maximumConfidenceDelta
            ) {
                matchingConfidenceContracts += 1
            }
            if expected.durationMS == actual.durationMS { durationMatches += 1 }
        }

        return WarmRuntimeParitySummary(
            comparisons: pairs.count,
            textMatches: textMatches,
            segmentMatches: segmentMatches,
            confidenceMatches: matchingConfidenceContracts,
            durationMatches: durationMatches,
            maximumConfidenceDelta: maximumConfidenceDelta,
            baselineCount: baseline.count,
            retainedCount: retained.count
        )
    }

    private static func segmentsMatch(
        _ expected: [TranscriptSegment],
        _ actual: [TranscriptSegment]
    ) -> Bool {
        guard expected.count == actual.count else { return false }
        return zip(expected, actual).allSatisfy { expected, actual in
            expected.startMS == actual.startMS
                && expected.endMS == actual.endMS
                && expected.text == actual.text
        }
    }

    private static func confidenceMatches(
        expected: RawTranscript,
        actual: RawTranscript,
        tolerance: Double,
        maximumDelta: inout Double?
    ) -> Bool {
        guard expected.segments.count == actual.segments.count else { return false }
        let expectedValues = [expected.avgConfidence] + expected.segments.map(\.confidence)
        let actualValues = [actual.avgConfidence] + actual.segments.map(\.confidence)
        var matches = true

        for (expectedValue, actualValue) in zip(expectedValues, actualValues) {
            switch (expectedValue, actualValue) {
            case (.none, .none):
                continue
            case (.some(let expected), .some(let actual)):
                let delta = abs(expected - actual)
                maximumDelta = max(maximumDelta ?? 0, delta)
                if delta > tolerance { matches = false }
            default:
                matches = false
            }
        }
        return matches
    }
}

public struct WarmRuntimeRepeatabilitySummary: Sendable, Codable, Equatable {
    public var repetitions: Int
    public var distinctTextVariantCount: Int
    public var distinctRichContractVariantCount: Int
    public var exactReferenceMatches: Int
    public var textReferenceMatches: Int
    public var exactlyRepeatable: Bool
    public var parity: WarmRuntimeParitySummary

    public init(
        repetitions: Int,
        distinctTextVariantCount: Int,
        distinctRichContractVariantCount: Int,
        exactReferenceMatches: Int,
        textReferenceMatches: Int,
        exactlyRepeatable: Bool,
        parity: WarmRuntimeParitySummary
    ) {
        self.repetitions = repetitions
        self.distinctTextVariantCount = distinctTextVariantCount
        self.distinctRichContractVariantCount = distinctRichContractVariantCount
        self.exactReferenceMatches = exactReferenceMatches
        self.textReferenceMatches = textReferenceMatches
        self.exactlyRepeatable = exactlyRepeatable
        self.parity = parity
    }

    public static func measure(
        reference: RawTranscript,
        repetitions: [RawTranscript],
        confidenceTolerance: Double = 0.000_001
    ) throws -> WarmRuntimeRepeatabilitySummary {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let richVariants = try Set(repetitions.map { try encoder.encode($0) })
        let parity = WarmRuntimeParitySummary.compare(
            baseline: Array(repeating: reference, count: repetitions.count),
            retained: repetitions,
            confidenceTolerance: confidenceTolerance
        )
        let exactMatches = repetitions.filter { $0 == reference }.count
        return WarmRuntimeRepeatabilitySummary(
            repetitions: repetitions.count,
            distinctTextVariantCount: Set(repetitions.map(\.text)).count,
            distinctRichContractVariantCount: richVariants.count,
            exactReferenceMatches: exactMatches,
            textReferenceMatches: repetitions.filter { $0.text == reference.text }.count,
            exactlyRepeatable: !repetitions.isEmpty
                && richVariants.count == 1
                && exactMatches == repetitions.count,
            parity: parity
        )
    }
}

public struct WarmRuntimeResourceCheckpoint: Sendable, Codable, Equatable {
    public var requestIndex: Int
    public var residentBytes: UInt64?
    public var physicalFootprintBytes: UInt64?

    public init(
        requestIndex: Int,
        residentBytes: UInt64?,
        physicalFootprintBytes: UInt64? = nil
    ) {
        self.requestIndex = requestIndex
        self.residentBytes = residentBytes
        self.physicalFootprintBytes = physicalFootprintBytes
    }
}

public struct WarmRuntimeResourceSummary: Sendable, Codable, Equatable {
    public var checkpoints: [WarmRuntimeResourceCheckpoint]
    public var monotonicGrowthObserved: Bool
    public var firstToLastGrowthBytes: Int64?
    public var peakGrowthBytesFromFirst: Int64?
    public var slopeBytesPerRequest: Double?
    public var tailSlopeBytesPerRequest: Double?
    public var physicalFootprintMonotonicGrowthObserved: Bool
    public var physicalFootprintFirstToLastGrowthBytes: Int64?
    public var physicalFootprintPeakGrowthBytesFromFirst: Int64?
    public var physicalFootprintSlopeBytesPerRequest: Double?
    public var physicalFootprintTailSlopeBytesPerRequest: Double?
    public var idleCPUPercent: Double?
    public var idleSampleSeconds: Double?
    public var postIdleResidentBytes: UInt64?
    public var postIdlePhysicalFootprintBytes: UInt64?
    public var postIdleResidentDeltaBytes: Int64?
    public var postIdlePhysicalFootprintDeltaBytes: Int64?

    public init(
        checkpoints: [WarmRuntimeResourceCheckpoint],
        monotonicGrowthObserved: Bool,
        firstToLastGrowthBytes: Int64?,
        peakGrowthBytesFromFirst: Int64? = nil,
        slopeBytesPerRequest: Double? = nil,
        tailSlopeBytesPerRequest: Double? = nil,
        physicalFootprintMonotonicGrowthObserved: Bool = false,
        physicalFootprintFirstToLastGrowthBytes: Int64? = nil,
        physicalFootprintPeakGrowthBytesFromFirst: Int64? = nil,
        physicalFootprintSlopeBytesPerRequest: Double? = nil,
        physicalFootprintTailSlopeBytesPerRequest: Double? = nil,
        idleCPUPercent: Double?,
        idleSampleSeconds: Double? = nil,
        postIdleResidentBytes: UInt64? = nil,
        postIdlePhysicalFootprintBytes: UInt64? = nil,
        postIdleResidentDeltaBytes: Int64? = nil,
        postIdlePhysicalFootprintDeltaBytes: Int64? = nil
    ) {
        self.checkpoints = checkpoints
        self.monotonicGrowthObserved = monotonicGrowthObserved
        self.firstToLastGrowthBytes = firstToLastGrowthBytes
        self.peakGrowthBytesFromFirst = peakGrowthBytesFromFirst ?? firstToLastGrowthBytes
        self.slopeBytesPerRequest = slopeBytesPerRequest
        let residentValues = checkpoints.compactMap { checkpoint -> (Int, UInt64)? in
            checkpoint.residentBytes.map { (checkpoint.requestIndex, $0) }
        }.sorted { $0.0 < $1.0 }
        self.tailSlopeBytesPerRequest = tailSlopeBytesPerRequest
            ?? Self.linearSlope(Self.tailValues(residentValues))
        self.physicalFootprintMonotonicGrowthObserved = physicalFootprintMonotonicGrowthObserved
        self.physicalFootprintFirstToLastGrowthBytes = physicalFootprintFirstToLastGrowthBytes
        self.physicalFootprintPeakGrowthBytesFromFirst = physicalFootprintPeakGrowthBytesFromFirst
            ?? physicalFootprintFirstToLastGrowthBytes
        self.physicalFootprintSlopeBytesPerRequest = physicalFootprintSlopeBytesPerRequest
        let physicalValues = checkpoints.compactMap { checkpoint -> (Int, UInt64)? in
            checkpoint.physicalFootprintBytes.map { (checkpoint.requestIndex, $0) }
        }.sorted { $0.0 < $1.0 }
        self.physicalFootprintTailSlopeBytesPerRequest = physicalFootprintTailSlopeBytesPerRequest
            ?? Self.linearSlope(Self.tailValues(physicalValues))
        self.idleCPUPercent = idleCPUPercent
        self.idleSampleSeconds = idleSampleSeconds
        self.postIdleResidentBytes = postIdleResidentBytes
        self.postIdlePhysicalFootprintBytes = postIdlePhysicalFootprintBytes
        self.postIdleResidentDeltaBytes = postIdleResidentDeltaBytes
        self.postIdlePhysicalFootprintDeltaBytes = postIdlePhysicalFootprintDeltaBytes
    }

    public static func analyze(
        checkpoints: [WarmRuntimeResourceCheckpoint],
        idleCPUPercent: Double? = nil,
        idleSampleSeconds: Double? = nil,
        postIdleResidentBytes: UInt64? = nil,
        postIdlePhysicalFootprintBytes: UInt64? = nil
    ) -> WarmRuntimeResourceSummary {
        let available = checkpoints.compactMap { checkpoint -> (Int, UInt64)? in
            checkpoint.residentBytes.map { (checkpoint.requestIndex, $0) }
        }.sorted { $0.0 < $1.0 }
        let monotonic = available.count > 1 && zip(available, available.dropFirst()).allSatisfy {
            $1.1 > $0.1
        }
        let growth: Int64?
        let peakGrowth: Int64?
        if let first = available.first?.1, let last = available.last?.1 {
            let delta = Int64(clamping: last) - Int64(clamping: first)
            growth = delta
            peakGrowth = available
                .map { Int64(clamping: $0.1) - Int64(clamping: first) }
                .max()
        } else {
            growth = nil
            peakGrowth = nil
        }
        let physical = checkpoints.compactMap { checkpoint -> (Int, UInt64)? in
            checkpoint.physicalFootprintBytes.map { (checkpoint.requestIndex, $0) }
        }.sorted { $0.0 < $1.0 }
        let physicalMonotonic = physical.count > 1 && zip(physical, physical.dropFirst()).allSatisfy {
            $1.1 > $0.1
        }
        let physicalGrowth = firstToLastGrowth(physical)
        let physicalPeakGrowth = peakGrowthFromFirst(physical)
        let lastResident = available.last?.1
        let lastPhysical = physical.last?.1
        return WarmRuntimeResourceSummary(
            checkpoints: checkpoints.sorted { $0.requestIndex < $1.requestIndex },
            monotonicGrowthObserved: monotonic,
            firstToLastGrowthBytes: growth,
            peakGrowthBytesFromFirst: peakGrowth,
            slopeBytesPerRequest: linearSlope(available),
            tailSlopeBytesPerRequest: linearSlope(tailValues(available)),
            physicalFootprintMonotonicGrowthObserved: physicalMonotonic,
            physicalFootprintFirstToLastGrowthBytes: physicalGrowth,
            physicalFootprintPeakGrowthBytesFromFirst: physicalPeakGrowth,
            physicalFootprintSlopeBytesPerRequest: linearSlope(physical),
            physicalFootprintTailSlopeBytesPerRequest: linearSlope(tailValues(physical)),
            idleCPUPercent: idleCPUPercent,
            idleSampleSeconds: idleSampleSeconds,
            postIdleResidentBytes: postIdleResidentBytes,
            postIdlePhysicalFootprintBytes: postIdlePhysicalFootprintBytes,
            postIdleResidentDeltaBytes: signedDelta(postIdleResidentBytes, from: lastResident),
            postIdlePhysicalFootprintDeltaBytes: signedDelta(
                postIdlePhysicalFootprintBytes,
                from: lastPhysical
            )
        )
    }

    private static func firstToLastGrowth(_ values: [(Int, UInt64)]) -> Int64? {
        guard let first = values.first?.1, let last = values.last?.1 else { return nil }
        return Int64(clamping: last) - Int64(clamping: first)
    }

    private static func peakGrowthFromFirst(_ values: [(Int, UInt64)]) -> Int64? {
        guard let first = values.first?.1 else { return nil }
        return values.map { Int64(clamping: $0.1) - Int64(clamping: first) }.max()
    }

    private static func signedDelta(_ value: UInt64?, from baseline: UInt64?) -> Int64? {
        guard let value, let baseline else { return nil }
        return Int64(clamping: value) - Int64(clamping: baseline)
    }

    private static func linearSlope(_ values: [(Int, UInt64)]) -> Double? {
        guard values.count > 1 else { return nil }
        let xs = values.map { Double($0.0) }
        let ys = values.map { Double($0.1) }
        guard let meanX = WarmRuntimeDistribution.mean(xs),
              let meanY = WarmRuntimeDistribution.mean(ys)
        else { return nil }
        let numerator = zip(xs, ys).reduce(0.0) { partial, pair in
            partial + ((pair.0 - meanX) * (pair.1 - meanY))
        }
        let denominator = xs.reduce(0.0) { partial, value in
            partial + ((value - meanX) * (value - meanX))
        }
        guard denominator > 0 else { return nil }
        return numerator / denominator
    }

    private static func tailValues(_ values: [(Int, UInt64)]) -> [(Int, UInt64)] {
        guard values.count > 1,
              let first = values.first?.0,
              let last = values.last?.0
        else { return values }
        let midpoint = first + ((last - first) / 2)
        let tail = values.filter { $0.0 >= midpoint }
        return tail.count > 1 ? tail : Array(values.suffix(2))
    }
}

public struct WarmRuntimeCancellationSummary: Sendable, Codable, Equatable {
    public var elapsedMS: Double
    public var cancelled: Bool
    public var lateResultObserved: Bool

    public init(elapsedMS: Double, cancelled: Bool, lateResultObserved: Bool) {
        self.elapsedMS = elapsedMS
        self.cancelled = cancelled
        self.lateResultObserved = lateResultObserved
    }
}

public struct WarmRuntimeModelSwitchSummary: Sendable, Codable, Equatable {
    public var reloadMS: Double
    public var firstInferenceMS: Double
    public var inferenceSucceeded: Bool
    public var helperProcessReplaced: Bool
    public var modelSHA256: String?
    public var vadModelSHA256: String?

    public init(
        reloadMS: Double,
        firstInferenceMS: Double,
        inferenceSucceeded: Bool,
        helperProcessReplaced: Bool,
        modelSHA256: String?,
        vadModelSHA256: String?
    ) {
        self.reloadMS = reloadMS
        self.firstInferenceMS = firstInferenceMS
        self.inferenceSucceeded = inferenceSucceeded
        self.helperProcessReplaced = helperProcessReplaced
        self.modelSHA256 = modelSHA256
        self.vadModelSHA256 = vadModelSHA256
    }
}

struct WarmRuntimeSwitchIdentity: Sendable, Equatable {
    var modelSHA256: String?
    var vadModelSHA256: String?

    static func resolve(
        currentModelSHA256: String?,
        currentVADModelSHA256: String?,
        requestedModelSHA256: String?,
        requestedVADModelSHA256: String?
    ) -> WarmRuntimeSwitchIdentity {
        WarmRuntimeSwitchIdentity(
            modelSHA256: requestedModelSHA256 ?? currentModelSHA256,
            vadModelSHA256: requestedVADModelSHA256 ?? currentVADModelSHA256
        )
    }
}

public struct WarmRuntimeConfigurationSummary: Sendable, Codable, Equatable {
    public var configurationSHA256: String?
    public var retainedHelperSHA256: String?
    public var switchModelSHA256: String?
    public var switchVADModelSHA256: String?
    public var threads: Int
    public var languageCategory: String
    public var vadEnabled: Bool
    public var suppressNonSpeechTokens: Bool
    public var beamSize: Int
    public var bestOf: Int
    public var comparisonIterations: Int
    public var resourceIterations: Int
    public var resourceCheckpointInterval: Int
    public var coordinatorIterations: Int
    public var repeatabilityIterations: Int
    public var cancellationDelayMS: Int
    public var idleSampleSeconds: Double
    public var modelSwitchRequested: Bool

    public init(
        configurationSHA256: String? = nil,
        retainedHelperSHA256: String? = nil,
        switchModelSHA256: String? = nil,
        switchVADModelSHA256: String? = nil,
        threads: Int,
        languageCategory: String,
        vadEnabled: Bool,
        suppressNonSpeechTokens: Bool,
        beamSize: Int,
        bestOf: Int,
        comparisonIterations: Int = 9,
        resourceIterations: Int = 100,
        resourceCheckpointInterval: Int = 25,
        coordinatorIterations: Int = 9,
        repeatabilityIterations: Int = 20,
        cancellationDelayMS: Int = 10,
        idleSampleSeconds: Double = 2,
        modelSwitchRequested: Bool = false
    ) {
        self.configurationSHA256 = configurationSHA256
        self.retainedHelperSHA256 = retainedHelperSHA256
        self.switchModelSHA256 = switchModelSHA256
        self.switchVADModelSHA256 = switchVADModelSHA256
        self.threads = threads
        self.languageCategory = languageCategory
        self.vadEnabled = vadEnabled
        self.suppressNonSpeechTokens = suppressNonSpeechTokens
        self.beamSize = beamSize
        self.bestOf = bestOf
        self.comparisonIterations = comparisonIterations
        self.resourceIterations = resourceIterations
        self.resourceCheckpointInterval = resourceCheckpointInterval
        self.coordinatorIterations = coordinatorIterations
        self.repeatabilityIterations = repeatabilityIterations
        self.cancellationDelayMS = cancellationDelayMS
        self.idleSampleSeconds = idleSampleSeconds
        self.modelSwitchRequested = modelSwitchRequested
    }
}

public struct WarmRuntimeImprovementSummary: Sendable, Codable, Equatable {
    public var meanReductionPercent: Double?
    public var p50ReductionPercent: Double?
    public var meanSpeedRatio: Double?

    public init(
        meanReductionPercent: Double?,
        p50ReductionPercent: Double?,
        meanSpeedRatio: Double?
    ) {
        self.meanReductionPercent = meanReductionPercent
        self.p50ReductionPercent = p50ReductionPercent
        self.meanSpeedRatio = meanSpeedRatio
    }

    static func compare(
        baseline: WarmRuntimeLatencySummary,
        retained: WarmRuntimeLatencySummary
    ) -> WarmRuntimeImprovementSummary {
        WarmRuntimeImprovementSummary(
            meanReductionPercent: reductionPercent(baseline.meanMS, retained.meanMS),
            p50ReductionPercent: reductionPercent(baseline.p50MS, retained.p50MS),
            meanSpeedRatio: ratio(baseline.meanMS, retained.meanMS)
        )
    }

    private static func reductionPercent(_ baseline: Double?, _ current: Double?) -> Double? {
        guard let baseline, baseline > 0, let current else { return nil }
        return ((baseline - current) / baseline) * 100
    }

    private static func ratio(_ baseline: Double?, _ current: Double?) -> Double? {
        guard let baseline, let current, current > 0 else { return nil }
        return baseline / current
    }
}

public struct WarmRuntimeCoordinatorModeSummary: Sendable, Codable, Equatable {
    public var captureCloseToTranscriptionStart: WarmRuntimeLatencySummary
    public var transcription: WarmRuntimeLatencySummary
    public var cleanup: WarmRuntimeLatencySummary
    public var insertionTransport: WarmRuntimeLatencySummary
    public var historyPersistence: WarmRuntimeLatencySummary
    public var stopToInsertionCompletion: WarmRuntimeLatencySummary
    public var coordinatorReturn: WarmRuntimeLatencySummary

    public init(
        captureCloseToTranscriptionStart: WarmRuntimeLatencySummary,
        transcription: WarmRuntimeLatencySummary,
        cleanup: WarmRuntimeLatencySummary,
        insertionTransport: WarmRuntimeLatencySummary,
        historyPersistence: WarmRuntimeLatencySummary,
        stopToInsertionCompletion: WarmRuntimeLatencySummary,
        coordinatorReturn: WarmRuntimeLatencySummary
    ) {
        self.captureCloseToTranscriptionStart = captureCloseToTranscriptionStart
        self.transcription = transcription
        self.cleanup = cleanup
        self.insertionTransport = insertionTransport
        self.historyPersistence = historyPersistence
        self.stopToInsertionCompletion = stopToInsertionCompletion
        self.coordinatorReturn = coordinatorReturn
    }
}

public struct WarmRuntimeCoordinatorComparison: Sendable, Codable, Equatable {
    public var cli: WarmRuntimeCoordinatorModeSummary
    public var retainedWarm: WarmRuntimeCoordinatorModeSummary

    public init(cli: WarmRuntimeCoordinatorModeSummary, retainedWarm: WarmRuntimeCoordinatorModeSummary) {
        self.cli = cli
        self.retainedWarm = retainedWarm
    }
}

public struct WarmRuntimeBenchmarkArtifact: Sendable, Codable {
    public var schemaVersion: String
    public var generatedAt: Date
    public var runtime: BenchmarkRuntimeMetadata
    public var identity: BenchmarkArtifactIdentity
    public var configuration: WarmRuntimeConfigurationSummary
    public var sampleCount: Int
    public var cli: WarmRuntimeLatencySummary
    public var retainedModelLoad: WarmRuntimeLatencySummary
    public var retainedColdInference: WarmRuntimeLatencySummary
    public var retainedWarm: WarmRuntimeLatencySummary
    public var warmImprovement: WarmRuntimeImprovementSummary
    public var coordinatorProxy: WarmRuntimeCoordinatorComparison?
    public var parity: WarmRuntimeParitySummary
    public var cliRepeatability: WarmRuntimeRepeatabilitySummary?
    public var retainedRepeatability: WarmRuntimeRepeatabilitySummary?
    public var resources: WarmRuntimeResourceSummary
    public var cancellation: WarmRuntimeCancellationSummary
    public var modelSwitch: WarmRuntimeModelSwitchSummary?
    public var networkListenersObserved: Bool?

    public init(
        schemaVersion: String = "steno-warm-runtime-benchmark/v1",
        generatedAt: Date = Date(),
        runtime: BenchmarkRuntimeMetadata = BenchmarkRuntimeMetadata(),
        identity: BenchmarkArtifactIdentity,
        configuration: WarmRuntimeConfigurationSummary,
        sampleCount: Int,
        cli: WarmRuntimeLatencySummary,
        retainedModelLoad: WarmRuntimeLatencySummary,
        retainedColdInference: WarmRuntimeLatencySummary,
        retainedWarm: WarmRuntimeLatencySummary,
        coordinatorProxy: WarmRuntimeCoordinatorComparison? = nil,
        parity: WarmRuntimeParitySummary,
        cliRepeatability: WarmRuntimeRepeatabilitySummary? = nil,
        retainedRepeatability: WarmRuntimeRepeatabilitySummary? = nil,
        resources: WarmRuntimeResourceSummary,
        cancellation: WarmRuntimeCancellationSummary,
        modelSwitch: WarmRuntimeModelSwitchSummary?,
        networkListenersObserved: Bool?
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.runtime = runtime
        self.identity = identity
        self.configuration = configuration
        self.sampleCount = sampleCount
        self.cli = cli
        self.retainedModelLoad = retainedModelLoad
        self.retainedColdInference = retainedColdInference
        self.retainedWarm = retainedWarm
        self.warmImprovement = .compare(baseline: cli, retained: retainedWarm)
        self.coordinatorProxy = coordinatorProxy
        self.parity = parity
        self.cliRepeatability = cliRepeatability
        self.retainedRepeatability = retainedRepeatability
        self.resources = resources
        self.cancellation = cancellation
        self.modelSwitch = modelSwitch
        self.networkListenersObserved = networkListenersObserved
    }
}

// MARK: - Blocking acceptance contract

public struct WarmRuntimeAcceptancePolicy: Sendable, Equatable {
    public var minimumMeanReductionPercent: Double
    public var minimumP50ReductionPercent: Double
    public var maximumTailRegressionPercent: Double
    public var maximumCancellationMS: Double
    public var maximumIdleCPUPercent: Double
    public var maximumPeakGrowthBytes: Int64
    public var maximumTailSlopeBytesPerRequest: Double

    public init(
        minimumMeanReductionPercent: Double = 40,
        minimumP50ReductionPercent: Double = 40,
        maximumTailRegressionPercent: Double = 5,
        maximumCancellationMS: Double = 250,
        maximumIdleCPUPercent: Double = 0.1,
        maximumPeakGrowthBytes: Int64 = 128 * 1024 * 1024,
        maximumTailSlopeBytesPerRequest: Double = 32 * 1024
    ) {
        self.minimumMeanReductionPercent = minimumMeanReductionPercent
        self.minimumP50ReductionPercent = minimumP50ReductionPercent
        self.maximumTailRegressionPercent = maximumTailRegressionPercent
        self.maximumCancellationMS = maximumCancellationMS
        self.maximumIdleCPUPercent = maximumIdleCPUPercent
        self.maximumPeakGrowthBytes = maximumPeakGrowthBytes
        self.maximumTailSlopeBytesPerRequest = maximumTailSlopeBytesPerRequest
    }
}

public enum WarmRuntimeAcceptanceFailure: String, Sendable, Codable, Equatable, CaseIterable {
    case missingIdentity
    case dirtyAppTree
    case incompleteComparison
    case insufficientMeanReduction
    case insufficientP50Reduction
    case p90Regression
    case p99Regression
    case contractDivergence
    case cliRepeatabilityDivergence
    case retainedRepeatabilityDivergence
    case missingResourceCheckpoints
    case missingResourceMeasurements
    case residentGrowthMonotonic
    case physicalGrowthMonotonic
    case residentGrowthUnbounded
    case physicalGrowthUnbounded
    case residentTailNotPlateaued
    case physicalTailNotPlateaued
    case idleCPUActivity
    case cancellationFailure
    case modelSwitchFailure
    case modelSwitchIdentityMismatch
    case networkProbeUnavailable
    case networkListenerObserved
}

public struct WarmRuntimeAcceptanceResult: Sendable, Equatable {
    public var accepted: Bool
    public var failures: [WarmRuntimeAcceptanceFailure]

    public init(failures: [WarmRuntimeAcceptanceFailure]) {
        self.failures = failures
        self.accepted = failures.isEmpty
    }
}

public enum WarmRuntimeAcceptanceValidator {
    public static func validate(
        _ artifact: WarmRuntimeBenchmarkArtifact,
        policy: WarmRuntimeAcceptancePolicy = WarmRuntimeAcceptancePolicy()
    ) -> WarmRuntimeAcceptanceResult {
        var failures: [WarmRuntimeAcceptanceFailure] = []
        func reject(_ failure: WarmRuntimeAcceptanceFailure, when condition: Bool) {
            if condition, !failures.contains(failure) {
                failures.append(failure)
            }
        }

        let identityValues = [
            artifact.identity.appCommitSHA,
            artifact.identity.engineCommitSHA,
            artifact.identity.manifestSHA256,
            artifact.identity.audioSetSHA256,
            artifact.identity.whisperCLISHA256,
            artifact.identity.modelSHA256,
            artifact.configuration.configurationSHA256,
            artifact.configuration.retainedHelperSHA256,
        ]
        reject(.missingIdentity, when: identityValues.contains(where: { $0?.isEmpty != false }))
        reject(
            .missingIdentity,
            when: artifact.configuration.vadEnabled && artifact.identity.vadModelSHA256?.isEmpty != false
        )
        reject(.dirtyAppTree, when: artifact.identity.appTreeIsDirty != false)

        let expectedComparisons = artifact.configuration.comparisonIterations
        reject(
            .incompleteComparison,
            when: expectedComparisons <= 0
                || artifact.cli.count != expectedComparisons
                || artifact.retainedWarm.count != expectedComparisons
                || artifact.parity.comparisons != expectedComparisons
        )

        let improvement = WarmRuntimeImprovementSummary.compare(
            baseline: artifact.cli,
            retained: artifact.retainedWarm
        )
        reject(
            .insufficientMeanReduction,
            when: (improvement.meanReductionPercent ?? -.infinity) < policy.minimumMeanReductionPercent
        )
        reject(
            .insufficientP50Reduction,
            when: (improvement.p50ReductionPercent ?? -.infinity) < policy.minimumP50ReductionPercent
        )
        reject(
            .p90Regression,
            when: tailRegressed(
                baseline: artifact.cli.p90MS,
                retained: artifact.retainedWarm.p90MS,
                maximumRegressionPercent: policy.maximumTailRegressionPercent
            )
        )
        reject(
            .p99Regression,
            when: tailRegressed(
                baseline: artifact.cli.p99MS,
                retained: artifact.retainedWarm.p99MS,
                maximumRegressionPercent: policy.maximumTailRegressionPercent
            )
        )

        reject(.contractDivergence, when: !artifact.parity.allContractsMatch)
        reject(
            .cliRepeatabilityDivergence,
            when: artifact.cliRepeatability?.exactlyRepeatable != true
                || artifact.cliRepeatability?.parity.allContractsMatch != true
        )
        reject(
            .retainedRepeatabilityDivergence,
            when: artifact.retainedRepeatability?.exactlyRepeatable != true
                || artifact.retainedRepeatability?.parity.allContractsMatch != true
        )

        let requiredCheckpoints: Set<Int> = [1, 10, 50, 100]
        let checkpointsByIndex = Dictionary(
            artifact.resources.checkpoints.map { ($0.requestIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        reject(
            .missingResourceCheckpoints,
            when: !requiredCheckpoints.isSubset(of: Set(checkpointsByIndex.keys))
        )
        reject(
            .missingResourceMeasurements,
            when: requiredCheckpoints.contains { index in
                checkpointsByIndex[index]?.residentBytes == nil
                    || checkpointsByIndex[index]?.physicalFootprintBytes == nil
            } || artifact.resources.idleCPUPercent == nil
        )
        reject(.residentGrowthMonotonic, when: artifact.resources.monotonicGrowthObserved)
        reject(
            .physicalGrowthMonotonic,
            when: artifact.resources.physicalFootprintMonotonicGrowthObserved
        )
        reject(
            .residentGrowthUnbounded,
            when: (artifact.resources.peakGrowthBytesFromFirst ?? .max)
                > policy.maximumPeakGrowthBytes
        )
        reject(
            .physicalGrowthUnbounded,
            when: (artifact.resources.physicalFootprintPeakGrowthBytesFromFirst ?? .max)
                > policy.maximumPeakGrowthBytes
        )
        reject(
            .residentTailNotPlateaued,
            when: (artifact.resources.tailSlopeBytesPerRequest ?? .infinity)
                > policy.maximumTailSlopeBytesPerRequest
        )
        reject(
            .physicalTailNotPlateaued,
            when: (artifact.resources.physicalFootprintTailSlopeBytesPerRequest ?? .infinity)
                > policy.maximumTailSlopeBytesPerRequest
        )
        reject(
            .idleCPUActivity,
            when: (artifact.resources.idleCPUPercent ?? .infinity) > policy.maximumIdleCPUPercent
        )

        reject(
            .cancellationFailure,
            when: !artifact.cancellation.cancelled
                || artifact.cancellation.lateResultObserved
                || artifact.cancellation.elapsedMS > policy.maximumCancellationMS
        )
        if artifact.configuration.modelSwitchRequested {
            let expectedModel = artifact.configuration.switchModelSHA256
            let expectedVAD = artifact.configuration.switchVADModelSHA256
            reject(
                .modelSwitchFailure,
                when: artifact.modelSwitch?.inferenceSucceeded != true
                    || artifact.modelSwitch?.helperProcessReplaced != true
            )
            reject(
                .modelSwitchIdentityMismatch,
                when: expectedModel == nil
                    || artifact.modelSwitch?.modelSHA256 != expectedModel
                    || artifact.modelSwitch?.vadModelSHA256 != expectedVAD
                    || (expectedModel == artifact.identity.modelSHA256
                        && expectedVAD == artifact.identity.vadModelSHA256)
            )
        } else if let modelSwitch = artifact.modelSwitch {
            reject(
                .modelSwitchFailure,
                when: !modelSwitch.inferenceSucceeded || !modelSwitch.helperProcessReplaced
            )
        }

        switch artifact.networkListenersObserved {
        case .none:
            reject(.networkProbeUnavailable, when: true)
        case .some(true):
            reject(.networkListenerObserved, when: true)
        case .some(false):
            break
        }

        return WarmRuntimeAcceptanceResult(failures: failures)
    }

    private static func tailRegressed(
        baseline: Double?,
        retained: Double?,
        maximumRegressionPercent: Double
    ) -> Bool {
        guard let baseline, baseline > 0, let retained else { return true }
        return retained > baseline * (1 + maximumRegressionPercent / 100)
    }
}

public enum WarmRuntimeArtifactEncoder {
    private static let prohibitedKeys: Set<String> = [
        "audiopath", "prompt", "vocabulary", "rawtext", "cleanedtext", "insertedtext",
        "referencetext", "hypothesistext", "transcript", "modelpath", "vadmodelpath",
        "helperexecutablepath", "appcontext", "bundleidentifier", "appname",
    ]

    public static func encode(_ artifact: WarmRuntimeBenchmarkArtifact) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(artifact)
        guard try validatePrivacy(of: data) else {
            throw WarmRuntimeBenchmarkError.privacyValidationFailed
        }
        return data
    }

    public static func validatePrivacy(of data: Data) throws -> Bool {
        let object = try JSONSerialization.jsonObject(with: data)
        return validate(object)
    }

    private static func validate(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if prohibitedKeys.contains(key.lowercased()) || !validate(child) {
                    return false
                }
            }
        } else if let array = value as? [Any] {
            return array.allSatisfy(validate)
        }
        return true
    }
}

// MARK: - Runner contract

public enum WarmRuntimeBenchmarkError: Error, LocalizedError {
    case emptyManifest
    case invalidIterationCount
    case helperProcessNotFound
    case privacyValidationFailed

    public var errorDescription: String? {
        switch self {
        case .emptyManifest:
            return "The warm-runtime benchmark manifest has no samples."
        case .invalidIterationCount:
            return "Warm-runtime comparison, coordinator, and repeatability iterations must be positive; resource iterations must be at least 100."
        case .helperProcessNotFound:
            return "The retained helper process was not present after the cold request."
        case .privacyValidationFailed:
            return "The warm-runtime benchmark artifact failed aggregate-only privacy validation."
        }
    }
}

public struct WarmRuntimeBenchmarkConfiguration: Sendable {
    public var manifestPath: String
    public var whisperCLIPath: String
    public var helperPath: String
    public var modelPath: String
    public var vadModelPath: String?
    public var switchModelPath: String?
    public var switchVADModelPath: String?
    public var threads: Int
    public var language: String
    public var suppressNonSpeechTokens: Bool
    public var suppressRegex: String?
    public var beamSize: Int
    public var bestOf: Int
    public var comparisonIterations: Int
    public var resourceIterations: Int
    public var resourceCheckpointInterval: Int
    public var coordinatorIterations: Int
    public var repeatabilityIterations: Int
    public var cancellationDelayMS: Int
    public var idleSampleSeconds: Double
    public var profile: StyleProfile
    public var lexicon: PersonalLexicon

    public init(
        manifestPath: String,
        whisperCLIPath: String,
        helperPath: String,
        modelPath: String,
        vadModelPath: String?,
        switchModelPath: String? = nil,
        switchVADModelPath: String? = nil,
        threads: Int = 6,
        language: String = "en",
        suppressNonSpeechTokens: Bool = true,
        suppressRegex: String? = nil,
        beamSize: Int = 5,
        bestOf: Int = 5,
        comparisonIterations: Int = 9,
        resourceIterations: Int = 100,
        resourceCheckpointInterval: Int = 25,
        coordinatorIterations: Int = 9,
        repeatabilityIterations: Int = 20,
        cancellationDelayMS: Int = 10,
        idleSampleSeconds: Double = 2,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) {
        self.manifestPath = manifestPath
        self.whisperCLIPath = whisperCLIPath
        self.helperPath = helperPath
        self.modelPath = modelPath
        self.vadModelPath = vadModelPath
        self.switchModelPath = switchModelPath
        self.switchVADModelPath = switchVADModelPath
        self.threads = max(1, threads)
        self.language = language
        self.suppressNonSpeechTokens = suppressNonSpeechTokens
        self.suppressRegex = suppressRegex
        self.beamSize = max(1, beamSize)
        self.bestOf = max(1, bestOf)
        self.comparisonIterations = comparisonIterations
        self.resourceIterations = resourceIterations
        self.resourceCheckpointInterval = max(1, resourceCheckpointInterval)
        self.coordinatorIterations = coordinatorIterations
        self.repeatabilityIterations = repeatabilityIterations
        self.cancellationDelayMS = max(0, cancellationDelayMS)
        self.idleSampleSeconds = max(0.1, idleSampleSeconds)
        self.profile = profile
        self.lexicon = lexicon
    }
}
