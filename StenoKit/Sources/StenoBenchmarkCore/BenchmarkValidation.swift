import Foundation
import StenoKit

public struct PipelineValidationThresholds: Sendable {
    public var maxWERDelta: Double
    public var maxCERDelta: Double
    public var maxRegressedSamples: Int
    public var minTermRecallAccuracy: Double?
    public var minRepairResolutionRate: Double?
    public var maxUnintendedRewriteRate: Double?
    public var minLiteralRepairPhrasePreservationRate: Double?
    public var maxPunctuationArtifactRate: Double?
    public var minCommandPassthroughAccuracy: Double?
    public var maxNoSpeechFalseInsertRate: Double?
    public var baselineP90LatencyMS: Double?
    public var maxP90RegressionRatio: Double?
    public var maxP90LatencyMS: Double?
    public var maxP99LatencyMS: Double?
    public var epsilon: Double

    public init(
        maxWERDelta: Double,
        maxCERDelta: Double,
        maxRegressedSamples: Int,
        minTermRecallAccuracy: Double? = nil,
        minRepairResolutionRate: Double? = nil,
        maxUnintendedRewriteRate: Double? = nil,
        minLiteralRepairPhrasePreservationRate: Double? = nil,
        maxPunctuationArtifactRate: Double? = nil,
        minCommandPassthroughAccuracy: Double? = nil,
        maxNoSpeechFalseInsertRate: Double? = nil,
        baselineP90LatencyMS: Double? = nil,
        maxP90RegressionRatio: Double? = nil,
        maxP90LatencyMS: Double? = nil,
        maxP99LatencyMS: Double? = nil,
        epsilon: Double = 1e-12
    ) {
        self.maxWERDelta = maxWERDelta
        self.maxCERDelta = maxCERDelta
        self.maxRegressedSamples = max(0, maxRegressedSamples)
        self.minTermRecallAccuracy = minTermRecallAccuracy
        self.minRepairResolutionRate = minRepairResolutionRate
        self.maxUnintendedRewriteRate = maxUnintendedRewriteRate
        self.minLiteralRepairPhrasePreservationRate = minLiteralRepairPhrasePreservationRate
        self.maxPunctuationArtifactRate = maxPunctuationArtifactRate
        self.minCommandPassthroughAccuracy = minCommandPassthroughAccuracy
        self.maxNoSpeechFalseInsertRate = maxNoSpeechFalseInsertRate
        self.baselineP90LatencyMS = baselineP90LatencyMS
        self.maxP90RegressionRatio = maxP90RegressionRatio
        self.maxP90LatencyMS = maxP90LatencyMS
        self.maxP99LatencyMS = maxP99LatencyMS
        self.epsilon = max(0, epsilon)
    }
}

public enum PipelineValidationError: Error, LocalizedError {
    case missingMetric(name: String)
    case releaseSignoffRequired(actualTier: BenchmarkEvidenceTier)
    case compatibilityMatrixUnavailable
    case compatibilityMatrixRowMissing(chipClass: AppleSiliconChipClass, memoryGB: Int, modelID: WhisperModelID)
    case werDeltaExceeded(actual: Double, maxAllowed: Double)
    case cerDeltaExceeded(actual: Double, maxAllowed: Double)
    case regressedSamplesExceeded(actual: Int, maxAllowed: Int)
    case termRecallAccuracyBelowThreshold(actual: Double, minRequired: Double)
    case repairResolutionRateBelowThreshold(actual: Double, minRequired: Double)
    case unintendedRewriteRateExceeded(actual: Double, maxAllowed: Double)
    case literalRepairPhrasePreservationRateBelowThreshold(actual: Double, minRequired: Double)
    case punctuationArtifactRateExceeded(actual: Double, maxAllowed: Double)
    case commandPassthroughAccuracyBelowThreshold(actual: Double, minRequired: Double)
    case noSpeechFalseInsertRateExceeded(actual: Double, maxAllowed: Double)
    case p90LatencyExceeded(actual: Double, maxAllowed: Double)
    case p99LatencyExceeded(actual: Double, maxAllowed: Double)
    case p90LatencyRegressionExceeded(actual: Double, baseline: Double, maxRatio: Double)

    public var errorDescription: String? {
        switch self {
        case .missingMetric(let name):
            return "Pipeline summary is missing required metric: \(name)"
        case .releaseSignoffRequired(let actualTier):
            return "Release-signoff thresholds require evidence tier releaseSignoff, but pipeline tier was \(actualTier.rawValue)"
        case .compatibilityMatrixUnavailable:
            return "Bundled whisper compatibility matrix is unavailable."
        case .compatibilityMatrixRowMissing(let chipClass, let memoryGB, let modelID):
            return "No whisper compatibility matrix row matched \(chipClass.rawValue) with \(memoryGB)GB for model \(modelID.rawValue)"
        case .werDeltaExceeded(let actual, let maxAllowed):
            return "Pipeline WER delta \(actual) exceeded max allowed \(maxAllowed)"
        case .cerDeltaExceeded(let actual, let maxAllowed):
            return "Pipeline CER delta \(actual) exceeded max allowed \(maxAllowed)"
        case .regressedSamplesExceeded(let actual, let maxAllowed):
            return "Pipeline regressed sample count \(actual) exceeded max allowed \(maxAllowed)"
        case .termRecallAccuracyBelowThreshold(let actual, let minRequired):
            return "Pipeline term recall accuracy \(actual) was below required minimum \(minRequired)"
        case .repairResolutionRateBelowThreshold(let actual, let minRequired):
            return "Pipeline repair trigger detection rate \(actual) was below required minimum \(minRequired)"
        case .unintendedRewriteRateExceeded(let actual, let maxAllowed):
            return "Pipeline unintended rewrite rate \(actual) exceeded max allowed \(maxAllowed)"
        case .literalRepairPhrasePreservationRateBelowThreshold(let actual, let minRequired):
            return "Pipeline literal repair phrase preservation rate \(actual) was below required minimum \(minRequired)"
        case .punctuationArtifactRateExceeded(let actual, let maxAllowed):
            return "Pipeline punctuation artifact rate \(actual) exceeded max allowed \(maxAllowed)"
        case .commandPassthroughAccuracyBelowThreshold(let actual, let minRequired):
            return "Pipeline command passthrough accuracy \(actual) was below required minimum \(minRequired)"
        case .noSpeechFalseInsertRateExceeded(let actual, let maxAllowed):
            return "Pipeline no-speech false insert rate \(actual) exceeded max allowed \(maxAllowed)"
        case .p90LatencyExceeded(let actual, let maxAllowed):
            return "Pipeline p90 latency \(actual)ms exceeded max allowed \(maxAllowed)ms"
        case .p99LatencyExceeded(let actual, let maxAllowed):
            return "Pipeline p99 latency \(actual)ms exceeded max allowed \(maxAllowed)ms"
        case .p90LatencyRegressionExceeded(let actual, let baseline, let maxRatio):
            return "Pipeline p90 latency \(actual)ms exceeded allowed regression ratio \(maxRatio) over baseline \(baseline)ms"
        }
    }
}

public enum BenchmarkValidation {
    public static func validatePipeline(
        _ pipeline: PipelineOutput,
        thresholds: PipelineValidationThresholds
    ) throws {
        if requiresReleaseSignoff(thresholds),
           pipeline.evidenceTier != .releaseSignoff {
            throw PipelineValidationError.releaseSignoffRequired(actualTier: pipeline.evidenceTier)
        }

        let matrixLatencyBudgets = try releaseLatencyBudgets(for: pipeline)

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

        if let minTermRecallAccuracy = thresholds.minTermRecallAccuracy {
            guard let termRecallAccuracy = pipeline.summary.termRecallAccuracy else {
                throw PipelineValidationError.missingMetric(name: "termRecallAccuracy")
            }
            if termRecallAccuracy + thresholds.epsilon < minTermRecallAccuracy {
                throw PipelineValidationError.termRecallAccuracyBelowThreshold(
                    actual: termRecallAccuracy,
                    minRequired: minTermRecallAccuracy
                )
            }
        }

        if let minRepairResolutionRate = thresholds.minRepairResolutionRate {
            guard let repairResolutionRate = pipeline.summary.repairResolutionRate else {
                throw PipelineValidationError.missingMetric(name: "repairResolutionRate")
            }
            if repairResolutionRate + thresholds.epsilon < minRepairResolutionRate {
                throw PipelineValidationError.repairResolutionRateBelowThreshold(
                    actual: repairResolutionRate,
                    minRequired: minRepairResolutionRate
                )
            }
        }

        if let maxUnintendedRewriteRate = thresholds.maxUnintendedRewriteRate {
            guard let unintendedRewriteRate = pipeline.summary.unintendedRewriteRate else {
                throw PipelineValidationError.missingMetric(name: "unintendedRewriteRate")
            }
            if unintendedRewriteRate > maxUnintendedRewriteRate + thresholds.epsilon {
                throw PipelineValidationError.unintendedRewriteRateExceeded(
                    actual: unintendedRewriteRate,
                    maxAllowed: maxUnintendedRewriteRate
                )
            }
        }

        if let minLiteralRepairPhrasePreservationRate = thresholds.minLiteralRepairPhrasePreservationRate {
            guard let literalRepairPhrasePreservationRate = pipeline.summary.literalRepairPhrasePreservationRate else {
                throw PipelineValidationError.missingMetric(name: "literalRepairPhrasePreservationRate")
            }
            if literalRepairPhrasePreservationRate + thresholds.epsilon < minLiteralRepairPhrasePreservationRate {
                throw PipelineValidationError.literalRepairPhrasePreservationRateBelowThreshold(
                    actual: literalRepairPhrasePreservationRate,
                    minRequired: minLiteralRepairPhrasePreservationRate
                )
            }
        }

        if let maxPunctuationArtifactRate = thresholds.maxPunctuationArtifactRate {
            guard let punctuationArtifactRate = pipeline.summary.punctuationArtifactRate else {
                throw PipelineValidationError.missingMetric(name: "punctuationArtifactRate")
            }
            if punctuationArtifactRate > maxPunctuationArtifactRate + thresholds.epsilon {
                throw PipelineValidationError.punctuationArtifactRateExceeded(
                    actual: punctuationArtifactRate,
                    maxAllowed: maxPunctuationArtifactRate
                )
            }
        }

        if let minCommandPassthroughAccuracy = thresholds.minCommandPassthroughAccuracy {
            if pipeline.summary.commandPassthroughCoverageRate == 0 {
                // Skip the threshold when the release corpus never exercised the
                // raw-leading-slash passthrough contract.
            } else {
                guard let commandPassthroughAccuracy = pipeline.summary.commandPassthroughAccuracy else {
                    throw PipelineValidationError.missingMetric(name: "commandPassthroughAccuracy")
                }
                if commandPassthroughAccuracy + thresholds.epsilon < minCommandPassthroughAccuracy {
                    throw PipelineValidationError.commandPassthroughAccuracyBelowThreshold(
                        actual: commandPassthroughAccuracy,
                        minRequired: minCommandPassthroughAccuracy
                    )
                }
            }
        }

        if let maxNoSpeechFalseInsertRate = thresholds.maxNoSpeechFalseInsertRate {
            guard let noSpeechFalseInsertRate = pipeline.summary.noSpeechFalseInsertRate else {
                throw PipelineValidationError.missingMetric(name: "noSpeechFalseInsertRate")
            }
            if noSpeechFalseInsertRate > maxNoSpeechFalseInsertRate + thresholds.epsilon {
                throw PipelineValidationError.noSpeechFalseInsertRateExceeded(
                    actual: noSpeechFalseInsertRate,
                    maxAllowed: maxNoSpeechFalseInsertRate
                )
            }
        }

        if let maxP90LatencyMS = thresholds.maxP90LatencyMS ?? matrixLatencyBudgets?.p90 {
            guard let p90LatencyMS = pipeline.summary.p90LatencyMS else {
                throw PipelineValidationError.missingMetric(name: "p90LatencyMS")
            }
            if p90LatencyMS > maxP90LatencyMS + thresholds.epsilon {
                throw PipelineValidationError.p90LatencyExceeded(
                    actual: p90LatencyMS,
                    maxAllowed: maxP90LatencyMS
                )
            }
        }

        if let baselineP90LatencyMS = thresholds.baselineP90LatencyMS,
           let maxP90RegressionRatio = thresholds.maxP90RegressionRatio {
            guard let p90LatencyMS = pipeline.summary.p90LatencyMS else {
                throw PipelineValidationError.missingMetric(name: "p90LatencyMS")
            }
            let maxAllowed = baselineP90LatencyMS * (1 + maxP90RegressionRatio)
            if p90LatencyMS > maxAllowed + thresholds.epsilon {
                throw PipelineValidationError.p90LatencyRegressionExceeded(
                    actual: p90LatencyMS,
                    baseline: baselineP90LatencyMS,
                    maxRatio: maxP90RegressionRatio
                )
            }
        }

        if let maxP99LatencyMS = thresholds.maxP99LatencyMS ?? matrixLatencyBudgets?.p99 {
            guard let p99LatencyMS = pipeline.summary.p99LatencyMS else {
                throw PipelineValidationError.missingMetric(name: "p99LatencyMS")
            }
            if p99LatencyMS > maxP99LatencyMS + thresholds.epsilon {
                throw PipelineValidationError.p99LatencyExceeded(
                    actual: p99LatencyMS,
                    maxAllowed: maxP99LatencyMS
                )
            }
        }
    }

    private static func requiresReleaseSignoff(_ thresholds: PipelineValidationThresholds) -> Bool {
        thresholds.minTermRecallAccuracy != nil
            || thresholds.minRepairResolutionRate != nil
            || thresholds.maxUnintendedRewriteRate != nil
            || thresholds.minLiteralRepairPhrasePreservationRate != nil
            || thresholds.maxPunctuationArtifactRate != nil
            || thresholds.minCommandPassthroughAccuracy != nil
            || thresholds.maxNoSpeechFalseInsertRate != nil
            || thresholds.baselineP90LatencyMS != nil
            || thresholds.maxP90RegressionRatio != nil
            || thresholds.maxP90LatencyMS != nil
            || thresholds.maxP99LatencyMS != nil
    }

    private static func releaseLatencyBudgets(
        for pipeline: PipelineOutput
    ) throws -> (p90: Double?, p99: Double?)? {
        guard pipeline.evidenceTier == .releaseSignoff else {
            return nil
        }
        guard let hardwareProfile = pipeline.hardwareProfile else {
            throw PipelineValidationError.missingMetric(name: "hardwareProfile")
        }
        let service: WhisperCompatibilityService
        do {
            service = try WhisperCompatibilityService.bundled()
        } catch {
            throw PipelineValidationError.compatibilityMatrixUnavailable
        }
        guard let row = service.row(
            for: hardwareProfile.chipClass,
            memoryGB: hardwareProfile.memoryGB,
            modelID: hardwareProfile.modelID
        ) else {
            throw PipelineValidationError.compatibilityMatrixRowMissing(
                chipClass: hardwareProfile.chipClass,
                memoryGB: hardwareProfile.memoryGB,
                modelID: hardwareProfile.modelID
            )
        }

        return (
            row.p90BudgetMS.map(Double.init),
            row.p99BudgetMS.map(Double.init)
        )
    }
}
