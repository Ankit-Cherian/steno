import Foundation
import Testing
@testable import StenoBenchmarkCore
import StenoKit

@Test("Warm-runtime summaries use nearest-rank percentiles and matched RTF inputs")
func warmRuntimeSummaryStatistics() {
    let summary = WarmRuntimeDistribution.summarize(
        milliseconds: [10, 20, 30, 40, 50],
        audioDurationMilliseconds: [1_000, 1_000, 1_000, 1_000, 1_000]
    )

    #expect(summary.count == 5)
    #expect(summary.meanMS == 30)
    #expect(summary.p50MS == 30)
    #expect(summary.p90MS == 50)
    #expect(summary.p99MS == 50)
    #expect(abs((summary.meanRTF ?? 0) - 0.03) < 0.000_000_001)
}

@Test("Warm-runtime parity distinguishes text, segment, and confidence contracts")
func warmRuntimeParityComparison() {
    let baseline = RawTranscript(
        text: "same transcript",
        segments: [
            TranscriptSegment(startMS: 0, endMS: 420, text: "same", confidence: 0.91),
            TranscriptSegment(startMS: 420, endMS: 900, text: " transcript", confidence: 0.88),
        ],
        avgConfidence: 0.895,
        durationMS: 900
    )
    let withinTolerance = RawTranscript(
        text: baseline.text,
        segments: [
            TranscriptSegment(startMS: 0, endMS: 420, text: "same", confidence: 0.910_000_4),
            TranscriptSegment(startMS: 420, endMS: 900, text: " transcript", confidence: 0.879_999_8),
        ],
        avgConfidence: 0.895_000_3,
        durationMS: baseline.durationMS
    )
    let changedSegment = RawTranscript(
        text: baseline.text,
        segments: [TranscriptSegment(startMS: 0, endMS: 900, text: baseline.text, confidence: 0.50)],
        avgConfidence: 0.50,
        durationMS: baseline.durationMS
    )

    let parity = WarmRuntimeParitySummary.compare(
        baseline: [baseline, baseline],
        retained: [withinTolerance, changedSegment],
        confidenceTolerance: 0.000_001
    )

    #expect(parity.comparisons == 2)
    #expect(parity.textMatches == 2)
    #expect(parity.segmentMatches == 1)
    #expect(parity.confidenceMatches == 1)
    #expect(parity.durationMatches == 2)
    #expect(parity.allContractsMatch == false)

    let missingResult = WarmRuntimeParitySummary.compare(
        baseline: [baseline, baseline],
        retained: [withinTolerance],
        confidenceTolerance: 0.000_001
    )
    #expect(missingResult.baselineCount == 2)
    #expect(missingResult.retainedCount == 1)
    #expect(missingResult.countMismatch)
    #expect(!missingResult.allContractsMatch)
}

@Test("Identical-audio repeatability counts text and full rich-contract variants without content")
func warmRuntimeIdenticalAudioRepeatability() throws {
    let reference = RawTranscript(
        text: "keep this punctuation.",
        segments: [TranscriptSegment(startMS: 0, endMS: 900, text: "keep this punctuation.", confidence: 0.9)],
        avgConfidence: 0.9,
        durationMS: 900
    )
    let confidenceVariant = RawTranscript(
        text: reference.text,
        segments: [TranscriptSegment(startMS: 0, endMS: 900, text: reference.text, confidence: 0.900_02)],
        avgConfidence: 0.900_02,
        durationMS: 900
    )
    let textVariant = RawTranscript(
        text: "keep this punctuation",
        segments: [TranscriptSegment(startMS: 0, endMS: 900, text: "keep this punctuation", confidence: 0.9)],
        avgConfidence: 0.9,
        durationMS: 900
    )

    let summary = try WarmRuntimeRepeatabilitySummary.measure(
        reference: reference,
        repetitions: [reference, confidenceVariant, textVariant],
        confidenceTolerance: 0.000_001
    )

    #expect(summary.repetitions == 3)
    #expect(summary.distinctTextVariantCount == 2)
    #expect(summary.distinctRichContractVariantCount == 3)
    #expect(summary.exactReferenceMatches == 1)
    #expect(summary.textReferenceMatches == 2)
    #expect(!summary.exactlyRepeatable)
    #expect(!summary.parity.allContractsMatch)
}

@Test("Warm-runtime resource checkpoints report monotonic RSS growth explicitly")
func warmRuntimeResourceGrowthSummary() {
    let increasing = WarmRuntimeResourceSummary.analyze(checkpoints: [
        WarmRuntimeResourceCheckpoint(requestIndex: 1, residentBytes: 100, physicalFootprintBytes: 200),
        WarmRuntimeResourceCheckpoint(requestIndex: 10, residentBytes: 110, physicalFootprintBytes: 205),
        WarmRuntimeResourceCheckpoint(requestIndex: 50, residentBytes: 130, physicalFootprintBytes: 215),
        WarmRuntimeResourceCheckpoint(requestIndex: 100, residentBytes: 160, physicalFootprintBytes: 225),
    ], postIdleResidentBytes: 155, postIdlePhysicalFootprintBytes: 220)
    let bounded = WarmRuntimeResourceSummary.analyze(checkpoints: [
        WarmRuntimeResourceCheckpoint(requestIndex: 1, residentBytes: 100),
        WarmRuntimeResourceCheckpoint(requestIndex: 10, residentBytes: 120),
        WarmRuntimeResourceCheckpoint(requestIndex: 50, residentBytes: 110),
        WarmRuntimeResourceCheckpoint(requestIndex: 100, residentBytes: 112),
    ])

    #expect(increasing.monotonicGrowthObserved)
    #expect(increasing.firstToLastGrowthBytes == 60)
    #expect(increasing.peakGrowthBytesFromFirst == 60)
    #expect((increasing.slopeBytesPerRequest ?? 0) > 0)
    #expect(increasing.physicalFootprintFirstToLastGrowthBytes == 25)
    #expect(increasing.physicalFootprintMonotonicGrowthObserved)
    #expect(increasing.postIdleResidentDeltaBytes == -5)
    #expect(increasing.postIdlePhysicalFootprintDeltaBytes == -5)
    #expect(!bounded.monotonicGrowthObserved)
    #expect(bounded.firstToLastGrowthBytes == 12)
    #expect(bounded.peakGrowthBytesFromFirst == 20)
}

@Test("Warm-runtime JSON artifact contains aggregate evidence only")
func warmRuntimeArtifactIsPrivacySafe() throws {
    let artifact = acceptedWarmRuntimeArtifact()

    let encoded = try WarmRuntimeArtifactEncoder.encode(artifact)
    let json = String(decoding: encoded, as: UTF8.self)
    let prohibited = [
        "audioPath", "prompt", "vocabulary", "transcript", "referenceText",
        "hypothesisText", "modelPath", "vadModelPath", "helperExecutablePath",
        "/Users/private", "private hot term", "raw dictated words",
    ]

    for term in prohibited {
        #expect(!json.localizedCaseInsensitiveContains(term))
    }
    #expect(try WarmRuntimeArtifactEncoder.validatePrivacy(of: encoded))
    #expect(json.contains("\"retainedModelLoad\""))
    #expect(json.contains("\"retainedColdInference\""))
    #expect(json.contains("\"reloadMS\""))
    #expect(json.contains("\"firstInferenceMS\""))
}

@Test("Warm-runtime acceptance is blocking for latency, parity, lifecycle, resources, and privacy boundaries")
func warmRuntimeAcceptanceValidatorBlocksFailedContracts() {
    let accepted = WarmRuntimeAcceptanceValidator.validate(acceptedWarmRuntimeArtifact())
    #expect(accepted.accepted)
    #expect(accepted.failures.isEmpty)

    var rejected = acceptedWarmRuntimeArtifact()
    rejected.identity.appTreeIsDirty = true
    rejected.retainedWarm = .init(
        count: 9,
        meanMS: 700,
        p50MS: 700,
        p90MS: 1_200,
        p99MS: 1_200,
        meanRTF: 0.07
    )
    rejected.parity.textMatches = 8
    rejected.resources.monotonicGrowthObserved = true
    rejected.resources.physicalFootprintMonotonicGrowthObserved = true
    rejected.resources.idleCPUPercent = 1
    rejected.cancellation = .init(elapsedMS: 500, cancelled: false, lateResultObserved: true)
    rejected.modelSwitch?.helperProcessReplaced = false
    rejected.networkListenersObserved = true

    let validation = WarmRuntimeAcceptanceValidator.validate(rejected)
    #expect(!validation.accepted)
    #expect(validation.failures.contains(.dirtyAppTree))
    #expect(validation.failures.contains(.insufficientMeanReduction))
    #expect(validation.failures.contains(.insufficientP50Reduction))
    #expect(validation.failures.contains(.p90Regression))
    #expect(validation.failures.contains(.p99Regression))
    #expect(validation.failures.contains(.contractDivergence))
    #expect(validation.failures.contains(.residentGrowthMonotonic))
    #expect(validation.failures.contains(.physicalGrowthMonotonic))
    #expect(validation.failures.contains(.idleCPUActivity))
    #expect(validation.failures.contains(.cancellationFailure))
    #expect(validation.failures.contains(.modelSwitchFailure))
    #expect(validation.failures.contains(.networkListenerObserved))
}

@Test("Warm-runtime acceptance rejects sawtooth resource growth that never reaches a bounded tail")
func warmRuntimeAcceptanceRejectsUnboundedSawtoothGrowth() {
    var rejected = acceptedWarmRuntimeArtifact()
    rejected.resources = WarmRuntimeResourceSummary.analyze(
        checkpoints: [
            .init(requestIndex: 1, residentBytes: 1_900_000_000, physicalFootprintBytes: 1_950_000_000),
            .init(requestIndex: 10, residentBytes: 2_020_000_000, physicalFootprintBytes: 2_070_000_000),
            .init(requestIndex: 50, residentBytes: 1_990_000_000, physicalFootprintBytes: 2_040_000_000),
            .init(requestIndex: 75, residentBytes: 2_120_000_000, physicalFootprintBytes: 2_170_000_000),
            .init(requestIndex: 100, residentBytes: 2_190_000_000, physicalFootprintBytes: 2_240_000_000),
        ],
        idleCPUPercent: 0,
        idleSampleSeconds: 30,
        postIdleResidentBytes: 2_190_000_000,
        postIdlePhysicalFootprintBytes: 2_240_000_000
    )

    #expect(!rejected.resources.monotonicGrowthObserved)
    #expect(!rejected.resources.physicalFootprintMonotonicGrowthObserved)

    let validation = WarmRuntimeAcceptanceValidator.validate(rejected)
    #expect(!validation.accepted)
    #expect(validation.failures.contains(.residentGrowthUnbounded))
    #expect(validation.failures.contains(.physicalGrowthUnbounded))
    #expect(validation.failures.contains(.residentTailNotPlateaued))
    #expect(validation.failures.contains(.physicalTailNotPlateaued))
}

@Test("Warm-runtime acceptance binds model-switch evidence to the requested model digests")
func warmRuntimeAcceptanceRejectsWrongSwitchIdentity() {
    var rejected = acceptedWarmRuntimeArtifact()
    rejected.modelSwitch?.modelSHA256 = String(repeating: "9", count: 64)

    let validation = WarmRuntimeAcceptanceValidator.validate(rejected)
    #expect(!validation.accepted)
    #expect(validation.failures.contains(.modelSwitchIdentityMismatch))
}

@Test("A model-only switch retains the effective VAD identity")
func warmRuntimeModelOnlySwitchRetainsVADIdentity() {
    let identity = WarmRuntimeSwitchIdentity.resolve(
        currentModelSHA256: "large-model",
        currentVADModelSHA256: "silero-vad",
        requestedModelSHA256: "small-model",
        requestedVADModelSHA256: nil
    )

    #expect(identity.modelSHA256 == "small-model")
    #expect(identity.vadModelSHA256 == "silero-vad")

    var artifact = acceptedWarmRuntimeArtifact()
    artifact.configuration.switchVADModelSHA256 = artifact.identity.vadModelSHA256
    artifact.modelSwitch?.vadModelSHA256 = artifact.identity.vadModelSHA256
    #expect(WarmRuntimeAcceptanceValidator.validate(artifact).accepted)
}

@Test("A VAD-only switch accepts an unchanged effective model identity")
func warmRuntimeVADOnlySwitchAcceptsUnchangedModelIdentity() {
    var artifact = acceptedWarmRuntimeArtifact()
    artifact.configuration.switchModelSHA256 = artifact.identity.modelSHA256
    artifact.modelSwitch?.modelSHA256 = artifact.identity.modelSHA256

    let validation = WarmRuntimeAcceptanceValidator.validate(artifact)
    #expect(validation.accepted)
    #expect(!validation.failures.contains(.modelSwitchIdentityMismatch))
}

private func acceptedWarmRuntimeArtifact() -> WarmRuntimeBenchmarkArtifact {
    WarmRuntimeBenchmarkArtifact(
        identity: BenchmarkArtifactIdentity(
            appCommitSHA: String(repeating: "a", count: 40),
            appTreeIsDirty: false,
            engineCommitSHA: String(repeating: "b", count: 40),
            manifestSHA256: String(repeating: "c", count: 64),
            audioSetSHA256: String(repeating: "d", count: 64),
            whisperCLISHA256: String(repeating: "e", count: 64),
            modelSHA256: String(repeating: "f", count: 64),
            vadModelSHA256: String(repeating: "0", count: 64)
        ),
        configuration: WarmRuntimeConfigurationSummary(
            configurationSHA256: String(repeating: "3", count: 64),
            retainedHelperSHA256: String(repeating: "4", count: 64),
            switchModelSHA256: String(repeating: "1", count: 64),
            switchVADModelSHA256: String(repeating: "2", count: 64),
            threads: 6,
            languageCategory: "en",
            vadEnabled: true,
            suppressNonSpeechTokens: true,
            beamSize: 5,
            bestOf: 5,
            modelSwitchRequested: true
        ),
        sampleCount: 3,
        cli: .init(count: 9, meanMS: 1_050, p50MS: 1_048, p90MS: 1_070, p99MS: 1_070, meanRTF: 0.105),
        retainedModelLoad: .init(count: 1, meanMS: 390, p50MS: 390, p90MS: 390, p99MS: 390, meanRTF: nil),
        retainedColdInference: .init(count: 1, meanMS: 260, p50MS: 260, p90MS: 260, p99MS: 260, meanRTF: 0.026),
        retainedWarm: .init(count: 9, meanMS: 265, p50MS: 264, p90MS: 275, p99MS: 275, meanRTF: 0.0265),
        parity: .init(
            comparisons: 9,
            textMatches: 9,
            segmentMatches: 9,
            confidenceMatches: 9,
            durationMatches: 9,
            maximumConfidenceDelta: 0.000_000_4
        ),
        cliRepeatability: repeatabilitySummary(repetitions: 20),
        retainedRepeatability: repeatabilitySummary(repetitions: 20),
        resources: .init(
            checkpoints: [
                .init(requestIndex: 1, residentBytes: 1_900_000_000, physicalFootprintBytes: 1_950_000_000),
                .init(requestIndex: 10, residentBytes: 1_910_000_000, physicalFootprintBytes: 1_960_000_000),
                .init(requestIndex: 50, residentBytes: 1_905_000_000, physicalFootprintBytes: 1_955_000_000),
                .init(requestIndex: 100, residentBytes: 1_906_000_000, physicalFootprintBytes: 1_956_000_000),
            ],
            monotonicGrowthObserved: false,
            firstToLastGrowthBytes: 6_000_000,
            physicalFootprintMonotonicGrowthObserved: false,
            physicalFootprintFirstToLastGrowthBytes: 6_000_000,
            idleCPUPercent: 0.001
        ),
        cancellation: .init(elapsedMS: 15, cancelled: true, lateResultObserved: false),
        modelSwitch: .init(
            reloadMS: 410,
            firstInferenceMS: 275,
            inferenceSucceeded: true,
            helperProcessReplaced: true,
            modelSHA256: String(repeating: "1", count: 64),
            vadModelSHA256: String(repeating: "2", count: 64)
        ),
        networkListenersObserved: false
    )
}

private func repeatabilitySummary(repetitions: Int) -> WarmRuntimeRepeatabilitySummary {
    WarmRuntimeRepeatabilitySummary(
        repetitions: repetitions,
        distinctTextVariantCount: 1,
        distinctRichContractVariantCount: 1,
        exactReferenceMatches: repetitions,
        textReferenceMatches: repetitions,
        exactlyRepeatable: true,
        parity: WarmRuntimeParitySummary(
            comparisons: repetitions,
            textMatches: repetitions,
            segmentMatches: repetitions,
            confidenceMatches: repetitions,
            durationMatches: repetitions,
            maximumConfidenceDelta: 0
        )
    )
}
