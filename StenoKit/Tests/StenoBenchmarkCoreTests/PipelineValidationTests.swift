import Testing
@testable import StenoBenchmarkCore
@testable import StenoKit

@Test("Pipeline validation passes when deltas are within thresholds")
func pipelineValidationPassesWithinThresholds() throws {
    let pipeline = makePipelineOutput(
        werDelta: 0.0,
        cerDelta: 0.0,
        regressed: 0
    )
    let thresholds = PipelineValidationThresholds(
        maxWERDelta: 0.0,
        maxCERDelta: 0.0,
        maxRegressedSamples: 0
    )

    try BenchmarkValidation.validatePipeline(pipeline, thresholds: thresholds)
}

@Test("Pipeline validation fails when WER delta exceeds threshold")
func pipelineValidationFailsOnWERDelta() {
    let pipeline = makePipelineOutput(
        werDelta: 0.0001,
        cerDelta: 0.0,
        regressed: 0
    )
    let thresholds = PipelineValidationThresholds(
        maxWERDelta: 0.0,
        maxCERDelta: 0.0,
        maxRegressedSamples: 0
    )

    do {
        try BenchmarkValidation.validatePipeline(pipeline, thresholds: thresholds)
        Issue.record("Expected WER threshold validation failure.")
    } catch PipelineValidationError.werDeltaExceeded(let actual, let maxAllowed) {
        #expect(actual == 0.0001)
        #expect(maxAllowed == 0.0)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("Pipeline validation fails when CER delta exceeds threshold")
func pipelineValidationFailsOnCERDelta() {
    let pipeline = makePipelineOutput(
        werDelta: 0.0,
        cerDelta: 0.0001,
        regressed: 0
    )
    let thresholds = PipelineValidationThresholds(
        maxWERDelta: 0.0,
        maxCERDelta: 0.0,
        maxRegressedSamples: 0
    )

    do {
        try BenchmarkValidation.validatePipeline(pipeline, thresholds: thresholds)
        Issue.record("Expected CER threshold validation failure.")
    } catch PipelineValidationError.cerDeltaExceeded(let actual, let maxAllowed) {
        #expect(actual == 0.0001)
        #expect(maxAllowed == 0.0)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("Pipeline validation fails when regressed sample count exceeds threshold")
func pipelineValidationFailsOnRegressedSamples() {
    let pipeline = makePipelineOutput(
        werDelta: 0.0,
        cerDelta: 0.0,
        regressed: 1
    )
    let thresholds = PipelineValidationThresholds(
        maxWERDelta: 0.0,
        maxCERDelta: 0.0,
        maxRegressedSamples: 0
    )

    do {
        try BenchmarkValidation.validatePipeline(pipeline, thresholds: thresholds)
        Issue.record("Expected regressed sample threshold validation failure.")
    } catch PipelineValidationError.regressedSamplesExceeded(let actual, let maxAllowed) {
        #expect(actual == 1)
        #expect(maxAllowed == 0)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("Pipeline validation fails when required deltas are missing")
func pipelineValidationFailsOnMissingDeltas() {
    let pipeline = makePipelineOutput(
        werDelta: nil,
        cerDelta: nil,
        regressed: 0
    )
    let thresholds = PipelineValidationThresholds(
        maxWERDelta: 0.0,
        maxCERDelta: 0.0,
        maxRegressedSamples: 0
    )

    do {
        try BenchmarkValidation.validatePipeline(pipeline, thresholds: thresholds)
        Issue.record("Expected missing metric validation failure.")
    } catch PipelineValidationError.missingMetric(let name) {
        #expect(name == "werDelta")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("Pipeline validation honors epsilon boundary")
func pipelineValidationHonorsEpsilon() throws {
    let pipeline = makePipelineOutput(
        werDelta: 0.0000000001,
        cerDelta: 0.0000000001,
        regressed: 0
    )
    let thresholds = PipelineValidationThresholds(
        maxWERDelta: 0.0,
        maxCERDelta: 0.0,
        maxRegressedSamples: 0,
        epsilon: 0.000000001
    )

    try BenchmarkValidation.validatePipeline(pipeline, thresholds: thresholds)
}

@Test("Pipeline validation fails when term recall accuracy drops below threshold")
func pipelineValidationFailsOnTermRecallAccuracy() {
    let pipeline = makePipelineOutput(
        werDelta: 0.0,
        cerDelta: 0.0,
        regressed: 0,
        termRecallAccuracy: 0.5,
        repairResolutionRate: 1.0,
        unintendedRewriteRate: 0.0,
        p90LatencyMS: 700,
        p99LatencyMS: 1_100
    )
    let thresholds = PipelineValidationThresholds(
        maxWERDelta: 0.0,
        maxCERDelta: 0.0,
        maxRegressedSamples: 0,
        minTermRecallAccuracy: 1.0,
        minRepairResolutionRate: 1.0,
        maxUnintendedRewriteRate: 0.0,
        baselineP90LatencyMS: 650,
        maxP90RegressionRatio: 0.10,
        maxP90LatencyMS: 800,
        maxP99LatencyMS: 1_200
    )

    do {
        try BenchmarkValidation.validatePipeline(pipeline, thresholds: thresholds)
        Issue.record("Expected term recall validation failure.")
    } catch PipelineValidationError.termRecallAccuracyBelowThreshold(let actual, let minRequired) {
        #expect(actual == 0.5)
        #expect(minRequired == 1.0)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("Pipeline validation fails when unintended rewrite rate or latency exceed thresholds")
func pipelineValidationFailsOnRewriteRateAndLatency() {
    let pipeline = makePipelineOutput(
        werDelta: 0.0,
        cerDelta: 0.0,
        regressed: 0,
        termRecallAccuracy: 1.0,
        repairResolutionRate: 1.0,
        unintendedRewriteRate: 0.25,
        p90LatencyMS: 900,
        p99LatencyMS: 1_300
    )
    let thresholds = PipelineValidationThresholds(
        maxWERDelta: 0.0,
        maxCERDelta: 0.0,
        maxRegressedSamples: 0,
        minTermRecallAccuracy: 1.0,
        minRepairResolutionRate: 1.0,
        maxUnintendedRewriteRate: 0.0,
        baselineP90LatencyMS: 700,
        maxP90RegressionRatio: 0.10,
        maxP90LatencyMS: 800,
        maxP99LatencyMS: 1_200
    )

    do {
        try BenchmarkValidation.validatePipeline(pipeline, thresholds: thresholds)
        Issue.record("Expected unintended rewrite validation failure.")
    } catch PipelineValidationError.unintendedRewriteRateExceeded(let actual, let maxAllowed) {
        #expect(actual == 0.25)
        #expect(maxAllowed == 0.0)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("Pipeline validation fails when literal preservation drops below threshold")
func pipelineValidationFailsOnLiteralPreservation() {
    let pipeline = makePipelineOutput(
        werDelta: 0.0,
        cerDelta: 0.0,
        regressed: 0,
        literalRepairPhrasePreservationRate: 0.5
    )
    let thresholds = PipelineValidationThresholds(
        maxWERDelta: 0.0,
        maxCERDelta: 0.0,
        maxRegressedSamples: 0,
        minLiteralRepairPhrasePreservationRate: 1.0
    )

    do {
        try BenchmarkValidation.validatePipeline(pipeline, thresholds: thresholds)
        Issue.record("Expected literal preservation validation failure.")
    } catch PipelineValidationError.literalRepairPhrasePreservationRateBelowThreshold(let actual, let minRequired) {
        #expect(actual == 0.5)
        #expect(minRequired == 1.0)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("Pipeline validation fails when punctuation artifacts or no-speech false inserts exceed thresholds")
func pipelineValidationFailsOnPunctuationAndNoSpeech() {
    let pipeline = makePipelineOutput(
        werDelta: 0.0,
        cerDelta: 0.0,
        regressed: 0,
        punctuationArtifactRate: 0.25,
        noSpeechFalseInsertRate: 0.25
    )
    let thresholds = PipelineValidationThresholds(
        maxWERDelta: 0.0,
        maxCERDelta: 0.0,
        maxRegressedSamples: 0,
        maxPunctuationArtifactRate: 0.0,
        maxNoSpeechFalseInsertRate: 0.0
    )

    do {
        try BenchmarkValidation.validatePipeline(pipeline, thresholds: thresholds)
        Issue.record("Expected punctuation artifact validation failure.")
    } catch PipelineValidationError.punctuationArtifactRateExceeded(let actual, let maxAllowed) {
        #expect(actual == 0.25)
        #expect(maxAllowed == 0.0)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("Pipeline validation rejects release thresholds for smoke fixture evidence tier")
func pipelineValidationRejectsReleaseThresholdsForSmokeFixture() {
    let pipeline = makePipelineOutput(
        werDelta: 0.0,
        cerDelta: 0.0,
        regressed: 0,
        evidenceTier: .smokeFixture
    )
    let thresholds = PipelineValidationThresholds(
        maxWERDelta: 0.0,
        maxCERDelta: 0.0,
        maxRegressedSamples: 0,
        minTermRecallAccuracy: 1.0,
        minRepairResolutionRate: 1.0,
        maxUnintendedRewriteRate: 0.0,
        baselineP90LatencyMS: 700,
        maxP90RegressionRatio: 0.10,
        maxP90LatencyMS: 800,
        maxP99LatencyMS: 1_200
    )

    do {
        try BenchmarkValidation.validatePipeline(pipeline, thresholds: thresholds)
        Issue.record("Expected smoke fixture release-threshold validation failure.")
    } catch PipelineValidationError.releaseSignoffRequired(let actualTier) {
        #expect(actualTier == .smokeFixture)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("Pipeline validation uses compatibility-matrix latency budgets for release signoff")
func pipelineValidationUsesCompatibilityMatrixLatencyBudgets() {
    let pipeline = makePipelineOutput(
        werDelta: 0.0,
        cerDelta: 0.0,
        regressed: 0,
        evidenceTier: .releaseSignoff,
        termRecallAccuracy: 1.0,
        repairResolutionRate: 1.0,
        unintendedRewriteRate: 0.0,
        p90LatencyMS: 850,
        p99LatencyMS: 1_250
    )
    let thresholds = PipelineValidationThresholds(
        maxWERDelta: 0.0,
        maxCERDelta: 0.0,
        maxRegressedSamples: 0,
        minTermRecallAccuracy: 1.0,
        minRepairResolutionRate: 1.0,
        maxUnintendedRewriteRate: 0.0
    )

    do {
        try BenchmarkValidation.validatePipeline(pipeline, thresholds: thresholds)
        Issue.record("Expected compatibility-matrix latency validation failure.")
    } catch PipelineValidationError.p99LatencyExceeded(let actual, let maxAllowed) {
        #expect(actual == 1_250)
        #expect(maxAllowed == 1_200)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func makePipelineOutput(
    werDelta: Double?,
    cerDelta: Double?,
    regressed: Int,
    evidenceTier: BenchmarkEvidenceTier = .releaseSignoff,
    termRecallAccuracy: Double? = 1.0,
    repairResolutionRate: Double? = 1.0,
    unintendedRewriteRate: Double? = 0.0,
    literalRepairPhrasePreservationRate: Double? = 1.0,
    punctuationArtifactRate: Double? = 0.0,
    commandPassthroughAccuracy: Double? = 1.0,
    noSpeechFalseInsertRate: Double? = 0.0,
    p50LatencyMS: Double? = 650,
    p90LatencyMS: Double? = 700,
    p99LatencyMS: Double? = 1_100
) -> PipelineOutput {
    let summary = PipelineAggregate(
        totalSamples: 1,
        scoredSamples: 1,
        rawWER: 0.03,
        rawCER: 0.01,
        cleanedWER: 0.03 + (werDelta ?? 0),
        cleanedCER: 0.01 + (cerDelta ?? 0),
        werDelta: werDelta,
        cerDelta: cerDelta,
        improved: 0,
        unchanged: 1 - regressed,
        regressed: regressed,
        unscored: 0,
        termRecallAccuracy: termRecallAccuracy,
        repairResolutionRate: repairResolutionRate,
        unintendedRewriteRate: unintendedRewriteRate,
        literalRepairPhrasePreservationRate: literalRepairPhrasePreservationRate,
        punctuationArtifactRate: punctuationArtifactRate,
        commandPassthroughAccuracy: commandPassthroughAccuracy,
        noSpeechFalseInsertRate: noSpeechFalseInsertRate,
        p50LatencyMS: p50LatencyMS,
        p90LatencyMS: p90LatencyMS,
        p99LatencyMS: p99LatencyMS,
        lexicon: .init(
            totalAppliedEdits: 0,
            editsMatchingReference: 0,
            editsNotMatchingReference: 0,
            referenceMatchAccuracy: nil
        ),
        fillerImpact: .init(
            samplesWithFillerRemovals: 0,
            totalRemovedFillers: 0,
            rawWEROnFillerSamples: nil,
            cleanedWEROnFillerSamples: nil,
            deltaWEROnFillerSamples: nil,
            improved: 0,
            unchanged: 0,
            regressed: 0
        )
    )

    return PipelineOutput(
        benchmarkName: "Validation Fixture",
        evidenceTier: evidenceTier,
        hardwareProfile: .init(chipClass: .m5Pro, memoryGB: 64, modelID: .largeV3Turbo),
        profile: .init(
            name: "benchmark-local",
            tone: .natural,
            structureMode: .natural,
            fillerPolicy: .balanced,
            commandPolicy: .passthrough
        ),
        lexiconEntryCount: 0,
        normalizationPolicy: .init(),
        summary: summary,
        samples: []
    )
}
