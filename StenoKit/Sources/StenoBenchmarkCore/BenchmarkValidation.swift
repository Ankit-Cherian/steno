import Foundation

public struct PipelineValidationThresholds: Sendable {
    public var maxWERDelta: Double
    public var maxCERDelta: Double
    public var maxRegressedSamples: Int
    public var epsilon: Double

    public init(
        maxWERDelta: Double,
        maxCERDelta: Double,
        maxRegressedSamples: Int,
        epsilon: Double = 1e-12
    ) {
        self.maxWERDelta = maxWERDelta
        self.maxCERDelta = maxCERDelta
        self.maxRegressedSamples = max(0, maxRegressedSamples)
        self.epsilon = max(0, epsilon)
    }
}

public enum PipelineValidationError: Error, LocalizedError {
    case missingMetric(name: String)
    case werDeltaExceeded(actual: Double, maxAllowed: Double)
    case cerDeltaExceeded(actual: Double, maxAllowed: Double)
    case regressedSamplesExceeded(actual: Int, maxAllowed: Int)

    public var errorDescription: String? {
        switch self {
        case .missingMetric(let name):
            return "Pipeline summary is missing required metric: \(name)"
        case .werDeltaExceeded(let actual, let maxAllowed):
            return "Pipeline WER delta \(actual) exceeded max allowed \(maxAllowed)"
        case .cerDeltaExceeded(let actual, let maxAllowed):
            return "Pipeline CER delta \(actual) exceeded max allowed \(maxAllowed)"
        case .regressedSamplesExceeded(let actual, let maxAllowed):
            return "Pipeline regressed sample count \(actual) exceeded max allowed \(maxAllowed)"
        }
    }
}

public enum BenchmarkValidation {
    public static func validatePipeline(
        _ pipeline: PipelineOutput,
        thresholds: PipelineValidationThresholds
    ) throws {
        guard let werDelta = pipeline.summary.werDelta else {
            throw PipelineValidationError.missingMetric(name: "werDelta")
        }
        if werDelta > thresholds.maxWERDelta + thresholds.epsilon {
            throw PipelineValidationError.werDeltaExceeded(
                actual: werDelta,
                maxAllowed: thresholds.maxWERDelta
            )
        }

        guard let cerDelta = pipeline.summary.cerDelta else {
            throw PipelineValidationError.missingMetric(name: "cerDelta")
        }
        if cerDelta > thresholds.maxCERDelta + thresholds.epsilon {
            throw PipelineValidationError.cerDeltaExceeded(
                actual: cerDelta,
                maxAllowed: thresholds.maxCERDelta
            )
        }

        let regressed = pipeline.summary.regressed
        if regressed > thresholds.maxRegressedSamples {
            throw PipelineValidationError.regressedSamplesExceeded(
                actual: regressed,
                maxAllowed: thresholds.maxRegressedSamples
            )
        }
    }
}
