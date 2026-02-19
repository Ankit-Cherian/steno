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

private func makePipelineOutput(
    werDelta: Double?,
    cerDelta: Double?,
    regressed: Int
) -> PipelineOutput {
    PipelineOutput(
        benchmarkName: "Validation Fixture",
        profile: .init(
            name: "benchmark-local",
            tone: .natural,
            structureMode: .natural,
            fillerPolicy: .balanced,
            commandPolicy: .passthrough
        ),
        lexiconEntryCount: 0,
        normalizationPolicy: .init(),
        summary: .init(
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
        ),
        samples: []
    )
}
